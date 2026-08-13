import SwiftUI
import SwiftData
import Observation

/// Drives the AnalysisQueue batch loop from the main actor and republishes
/// its statistics for the UI.
@MainActor
@Observable
final class AnalysisModel {
    private(set) var stats: AnalysisStatistics?
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Whether the run that isn't going was stopped rather than finished — by
    /// the user, or (iPhone and iPad) by whatever ended a continued background
    /// run, which the app cannot tell apart from the user stopping it there.
    /// Either way the app must not start it again by itself.
    ///
    /// FR-3.5 offers exactly two controls — stopping a run, and resuming one
    /// the user stopped — so this is the difference between "nothing to
    /// resume" and a Resume button. It is also what keeps the app from
    /// restarting the very run the user just stopped: every automatic start
    /// (catching up with the library, coming back to the foreground) goes
    /// through `startUnlessStopped`, which honours it, while the Resume button
    /// and the menu command call `start` and clear it.
    private(set) var isStoppedByUser = false
    /// Non-nil while the run is alive but deliberately not working — the
    /// device is warm or on battery-saving terms (FR-3.6), or iCloud downloads
    /// are the only work left and the network doesn't allow them (FR-3.7).
    /// The run stays running: this is a pause the user can see and stop, not
    /// a silent stall.
    private(set) var waitingReason: AnalysisWait?
    /// Non-nil while the run is actually working, saying what this device
    /// cannot promise about carrying on unattended (FR-3.6, FR-8.12). Cleared
    /// whenever the run is only waiting — nothing is being continued then, so
    /// there is nothing to disclaim.
    private(set) var unattendedLimit: UnattendedRunLimit?
    #if os(iOS)
    /// Whether the run that isn't going ended in the background rather than at
    /// the user's press of Stop — as far as the app can tell, which is not far
    /// (see `UnattendedRunLimit.endedInBackground`). Kept apart from
    /// `isStoppedByUser` because it answers a different question: that one
    /// decides whether the app may start a run again by itself, this one
    /// decides what the card says about the one that ended.
    private var stoppedInBackground = false
    #endif

    private var queue: AnalysisQueue?
    private var runTask: Task<Void, Never>?

    func refresh(container: ModelContainer) async {
        stats = try? await ensureQueue(container).statistics()
    }

    /// Starts the batch loop if idle and returns the running task. Re-entry
    /// while running returns the in-flight task, so an automatic start and a
    /// press of Resume never double-run.
    ///
    /// Deliberately not awaited by anything: a run with deferred iCloud work
    /// left in it does not end (see the retry wait below), so "wait for
    /// analysis to finish" is not a thing a caller can meaningfully do any
    /// more. The task is returned for the re-entry chaining alone.
    ///
    /// This is where FR-3.6 is implemented in full: a run can be stopped at any
    /// moment, it pauses with a stated reason when the machine is warm or
    /// saving power (see `RunConditions`), and it keeps going while
    /// nobody is watching — by asking the system to continue it once the app
    /// leaves the foreground (`ContinuedAnalysisTask`, iPhone and iPad) and by
    /// holding the Mac out of idle sleep for as long as it works
    /// (`UnattendedRun`). Neither guarantee is total, and the same object
    /// publishes the limit for the card to state (FR-8.12) rather than letting
    /// the app look like it is still working when the platform has stopped it.
    ///
    /// **The continue-while-locked part is shipped unverified.** Its only API
    /// is `BGContinuedProcessingTask` (iOS 26+), and Apple DTS confirmed the
    /// iOS 26 implementation stops progressing the moment the device locks —
    /// the assertion meant to keep the device awake was left off
    /// (developer.apple.com/forums/thread/796138). Nothing in the iOS 27 SDK
    /// or its documentation says that changed, and it could not be checked
    /// here: lock-screen behaviour needs a real device, and no iOS runtime is
    /// installed. So treat that one clause as untested rather than assuming
    /// the rest of this function's verification covers it. What *is* certain
    /// is the failure mode — every path in `ContinuedAnalysisTask` degrades to
    /// ordinary foreground analysis, and the loop below never reports progress
    /// it isn't making (FR-3.4).
    ///
    /// Starting and stopping stay cheap because progress is saved per batch
    /// (`AnalysisQueue.processNextBatch`), so an interrupted run resumes where
    /// it stopped rather than restarting (FR-3.3, FR-7.1).
    @discardableResult
    func start(container: ModelContainer) -> Task<Void, Never> {
        isStoppedByUser = false
        if let runTask, isRunning { return runTask }
        // A previous run may still be finishing its rescore (it clears
        // `isRunning` before that, so the guard above lets us through). Hold on
        // to it and wait for it below rather than starting on top of it.
        let previousRun = runTask
        isRunning = true
        let queue = ensureQueue(container)

        #if os(iOS)
        // FR-3.6: ask the system to let this run continue once the app is no
        // longer on screen. Best-effort by construction — if it is refused the
        // loop below is unchanged and simply only advances in the foreground.
        // The shared owner, not a fresh one per run: see ContinuedAnalysisTask.
        let continued = ContinuedAnalysisTask.shared
        stoppedInBackground = false
        Task { await continued.begin(onCancel: { [weak self] in self?.stopFromBackground() }) }
        #endif

        let task = Task {
            // Never two rescores at once: both write the weights file and the
            // whole preference-score cache.
            await previousRun?.value
            // This run's own error, published to `lastError` only once the run
            // is over. Clearing `lastError` up front instead — which is what
            // this used to do — meant a failed run retried blanked the message
            // at the bottom of the card, let the candidate grid slide up into
            // the gap, and then printed the same message again seconds later.
            // FR-8.7 asks that redoing something move nothing at all, so the
            // old message stands until this run has its own answer to put
            // there.
            var runError: String?
            /// Whether anything has been analyzed since the ranking was last
            /// brought up to date. A run that ends does that on its way out —
            /// but a run holding deferred iCloud work never ends (FR-3.4), so
            /// without this the photos it just accepted would sit unscored at
            /// the bottom of the grid for as long as one photo stayed stuck in
            /// iCloud. Seeded `true` so the first pass through the wait
            /// rescores whatever the local work found.
            var analyzedSinceRescore = true
            #if os(iOS)
            // Set once the run has told the system it no longer needs to be
            // kept alive — see the deferred-retry wait below.
            var continuedReleased = false
            #endif
            do {
                await queue.beginSession()
                while !Task.isCancelled {
                    // FR-3.6: hold off between batches while the device is
                    // warm or saving power. Batches are already the save
                    // point, so pausing here costs no progress. `Task.sleep`
                    // throws on cancellation, so Stop still lands instantly
                    // even mid-wait (FR-3.3).
                    if let pause = RunConditions.pauseReason() {
                        waitingReason = pause
                        setUnattended(false)
                        try await Task.sleep(for: Thresholds.analysisPauseRecheckInterval)
                        continue
                    }

                    // FR-3.7: only ask PhotoKit to download originals when the
                    // user's network settings allow it.
                    let networkWait = RunConditions.iCloudDownloadWait
                    waitingReason = nil
                    // FR-3.6: about to do real work, so claim the machine for
                    // it — and re-read the power source, so unplugging a laptop
                    // mid-run changes both what is held and what the user is
                    // told, within one batch.
                    setUnattended(true)

                    guard let processed = try await queue.processNextBatch(allowNetworkDownloads: networkWait == nil),
                          processed > 0 else {
                        let current = try await queue.statistics()
                        stats = current
                        // Local work is done. Anything still deferred is
                        // iCloud's to deliver, and FR-3.4 makes chasing it the
                        // app's job rather than the user's: there is no retry
                        // button anywhere, so this run does not end while
                        // deferred records remain — it waits and comes back to
                        // them. Which wait it is depends on why they are still
                        // sitting there: a network the user's settings hold
                        // back (FR-3.7) is re-tested on the short interval,
                        // while a round that was allowed to download and got
                        // nowhere waits the long one before asking again, so a
                        // photo whose download keeps failing costs one attempt
                        // every few minutes rather than a spin.
                        //
                        // The run staying alive is the honest state, not an
                        // oversight: FR-3.4 forbids claiming completion while
                        // deferred work remains, and FR-3.5 has the tab report
                        // what the pipeline is doing and offer stopping it —
                        // which is exactly what an unfinished run offers.
                        guard current.skipped > 0 else { break }
                        #if os(iOS)
                        // Nothing is being processed from here on, only waited
                        // for, and the system reclaims a continued task that
                        // reports no progress — which would arrive as a
                        // cancellation and read to the user as if the run had
                        // been stopped. Hand it back instead; the wait costs
                        // nothing to keep in the foreground.
                        if !continuedReleased {
                            continued.end(success: true)
                            continuedReleased = true
                        }
                        #endif
                        // Local work is done for now, so this is the moment
                        // the ranking would have been refreshed if the run had
                        // ended here — and from the user's point of view it
                        // has: everything reachable is analyzed, and the grid
                        // has to show it in its right place (FR-4.5).
                        if analyzedSinceRescore {
                            analyzedSinceRescore = false
                            try? await PreferenceRanker(modelContainer: container).prepare()
                            RankingClock.shared.bump()
                        }
                        waitingReason = networkWait ?? .iCloudRetryPending
                        // Nothing is being analyzed from here on, only waited
                        // for — possibly for a long time, if a download stays
                        // stuck. Holding a Mac awake through that would be the
                        // app spending the user's machine on nothing, and
                        // saying it "keeps going while you're away" would be
                        // claiming work that isn't happening (FR-8.12). The
                        // same reasoning hands the iOS continued task back, a
                        // few lines above.
                        setUnattended(false)
                        if networkWait != nil {
                            try await Task.sleep(for: Thresholds.analysisPauseRecheckInterval)
                        } else {
                            try await Task.sleep(for: Thresholds.deferredRetryInterval)
                            // Makes the records this session already tried
                            // eligible again — the point of coming back.
                            await queue.beginSession()
                        }
                        continue
                    }
                    analyzedSinceRescore = true
                    let current = try await queue.statistics()
                    stats = current
                    #if os(iOS)
                    // The system reclaims a continued task that looks stalled,
                    // so report real progress on every batch.
                    continued.update(completed: current.completed, total: current.total)
                    #endif
                }
            } catch is CancellationError {
                // Stopped by the user; resumable by design.
            } catch {
                runError = error.localizedDescription
            }
            lastError = runError
            #if os(iOS)
            if !continuedReleased { continued.end(success: runError == nil) }
            #endif
            // However the run ended — finished, stopped, or thrown out of —
            // the machine goes back to sleeping when it likes.
            setUnattended(false)
            #if os(iOS)
            // A run the app didn't end and the user may not have either: say
            // so where the run's other unattended statements are said, rather
            // than leave a Resume button standing there implying the user
            // asked for the stop (FR-3.6, FR-8.12).
            if stoppedInBackground { unattendedLimit = .endedInBackground }
            #endif
            waitingReason = nil
            stats = try? await queue.statistics()
            // Analysis is over at this point — what follows is the ranking
            // refresh, not more analysing — so the card stops offering "Stop"
            // and a spinner now rather than seconds later. Leaving it set
            // through the rescore below made a stopped run look like it was
            // still working, which is the same false-progress FR-3.4 rules out
            // for iCloud waits.
            isRunning = false
            // Newly accepted photos carry no cached preference score and would
            // otherwise sit unranked at the bottom of the grid until the Duel
            // tab runs; rescore now so ranking is current, then tell views.
            try? await PreferenceRanker(modelContainer: container).prepare()
            RankingClock.shared.bump()
        }
        runTask = task
        return task
    }

    /// The user's Stop (FR-3.3, FR-3.5). Stops after the in-flight batch;
    /// progress is already saved per batch.
    ///
    /// Records that the stop was the user's, which is what keeps the app from
    /// simply starting the run again a moment later — every automatic start
    /// goes through `startUnlessStopped`. Only pressing Resume (or the menu
    /// command of the same name) clears it.
    ///
    /// Cancels but deliberately does **not** clear `runTask`: the task lives on
    /// through its rescore, and `start` chains the next run onto it. Clearing
    /// it here would defeat that — the re-entry guard reads `runTask`, so a
    /// quick Stop → Resume would slip past it and run two `prepare()`s at once,
    /// both writing the weights file and the score cache.
    func stop() {
        isStoppedByUser = true
        #if os(iOS)
        // This one the app *does* know the author of, so the card must not go
        // on hedging about it.
        stoppedInBackground = false
        #endif
        runTask?.cancel()
    }

    #if os(iOS)
    /// The end of a continued background run — the system reclaiming it, or
    /// the user cancelling it from the system's own progress UI. The two are
    /// indistinguishable at this API, so this stops the run exactly as the
    /// user's Stop does (never restarting something the user may have just
    /// cancelled — FR-3.3) and records that the app cannot say which happened,
    /// which is what the card then tells the user instead of picking one
    /// (FR-3.6, FR-8.12).
    ///
    /// A stop the user made *in the app* moments earlier wins: it is the one
    /// version of events that isn't a guess, and the expiration handler firing
    /// afterwards is just the task being torn down as a result.
    func stopFromBackground() {
        guard !isStoppedByUser else { return }
        stoppedInBackground = true
        isStoppedByUser = true
        runTask?.cancel()
    }
    #endif

    /// Starts a run unless the user has stopped one (FR-3.5's "work the app
    /// should be doing anyway is never gated behind a button", held against
    /// FR-3.3's "analysis can be interrupted at any time" — an interruption
    /// that the app immediately undoes is not one).
    func startUnlessStopped(container: ModelContainer) {
        guard !isStoppedByUser else { return }
        start(container: container)
    }

    /// Stops the run and waits for it to finish, without counting as the
    /// user's stop.
    ///
    /// Catching up with the library needs the store to itself — the scan walks
    /// and rewrites the very records the queue is analyzing — so a catch-up
    /// stands the run down first and starts it again afterwards. Nothing is
    /// lost: analysis is saved per batch and resumes where it stopped (FR-7.1).
    ///
    /// Gated on `runTask` alone, not `runTask, isRunning`: `isRunning` is
    /// cleared *before* the tail-end rescore (`PreferenceRanker.prepare()` +
    /// `RankingClock.bump()`, above) runs, so a caller arriving in that window
    /// would see `isRunning == false` and return immediately — while the
    /// outgoing run is still writing the weights file and the score cache from
    /// its own `ModelContext`. That's precisely the overlap this function
    /// exists to rule out. Awaiting `runTask.value` whenever one exists closes
    /// the window: cancelling and awaiting an already-finished task is a
    /// harmless no-op, so the only behavior change from the wider guard is
    /// that this now genuinely waits out that tail whenever it's still
    /// in flight.
    func standDownForCatchUp() async {
        guard let runTask else { return }
        runTask.cancel()
        await runTask.value
    }

    /// FR-3.6: tells the unattended-run owner whether this run is working right
    /// now, and republishes what it says this device can't promise.
    ///
    /// Both halves in one call because they are one fact: the disclosure has to
    /// describe the assertion actually being held, or the card would explain a
    /// state the app isn't in.
    private func setUnattended(_ isWorking: Bool) {
        UnattendedRun.shared.update(isRunning: isWorking)
        unattendedLimit = UnattendedRun.shared.limit
    }

    private func ensureQueue(_ container: ModelContainer) -> AnalysisQueue {
        if let queue { return queue }
        let created = AnalysisQueue(modelContainer: container)
        queue = created
        return created
    }
}

/// Vision analysis card: progress, per-reason rejection counts, run controls.
struct AnalysisView: View {
    @Environment(\.modelContext) private var modelContext

    /// Owned by the Library tab so the startup auto-resync can drive the same
    /// loop the manual buttons do.
    let model: AnalysisModel

    /// Changes when a scan completes, triggering a statistics refresh.
    let scanToken: Int?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vision Analysis")
                    .font(.headline)

                if let stats = model.stats {
                    if stats.total == 0 {
                        Text("Nothing to analyze yet — analysis runs on the candidates the library pass finds, as it finds them.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        content(stats)
                    }
                } else {
                    // The statistics are a handful of SwiftData counts, which
                    // normally land well inside the delay — so on the usual
                    // launch this card fills in without ever having shown a
                    // spinner (FR-8.7). Only a genuinely slow first fetch
                    // against a cold store surfaces one.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .shownWhileWaiting()
                }

                if let error = model.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
            // Stretch from *inside* the box, not from the call site: `GroupBox`
            // sizes to its content and ignores a width proposed from outside,
            // so `.frame(maxWidth:)` on the `GroupBox` itself does nothing.
            // Without this the card shrink-wraps its widest row and renders
            // far narrower than the column it sits in, which on iPad left this
            // and the Library Scan card visibly mismatched (FR-8.1). The same
            // modifier is on `LibraryStatusView`'s content so the two stay equal.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: scanToken) {
            await model.refresh(container: modelContext.container)
        }
    }

    @ViewBuilder
    private func content(_ stats: AnalysisStatistics) -> some View {
        ProgressView(value: Double(stats.completed), total: Double(max(stats.total, 1)))
        Text(progressCaption(stats))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            // Two lines, always, whether or not they are used (FR-8.7). This
            // caption swaps between a short and a long form mid-run — the
            // iCloud download wording is roughly twice the length — and on a
            // narrow enough card the longer one wraps, which would push the
            // breakdown and the Stop button down as the run's own state
            // changed. Reserving the second line up front costs one blank line
            // and keeps everything below it still.
            .lineLimit(2, reservesSpace: true)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            statRow("checkmark.seal", .green, "Wallpaper candidates", stats.accepted,
                    help: "Photos that passed every analysis check and compete for the wallpaper album.")
            statRow("person.2.slash", .secondary, "People", stats.people,
                    help: "Rejected: people were detected in these photos.")
            statRow("doc.viewfinder", .secondary, "Utility images", stats.utility,
                    help: "Rejected: these look like documents, screenshots, or other utility images.")
            statRow("photo.trianglebadge.exclamationmark", .secondary, "Blurred or obstructed", stats.flawed,
                    help: "Rejected: these are badly blurred or smeared, or something like a finger blocked the lens.")
            // Plain leaf: the row label carries the negation (no leaf.slash
            // exists, and the arrow variant is the recycling symbol).
            statRow("leaf", .secondary, "Not nature", stats.notNature,
                    help: "Rejected: these don't look like nature scenes.")
            statRow("icloud.and.arrow.down", .orange, "iCloud (deferred)", stats.skipped,
                    help: "Deferred: the originals are in iCloud and not downloaded yet. Firnlight comes back to them itself once the network and the device allow the download.")
            // Only shown when there is something to report. FR-3.2 fixes the
            // set-aside reasons the user is offered, and this isn't one of
            // them — it's the app admitting it couldn't look, rather than a
            // judgment about the photo. Hiding it at zero keeps the normal
            // breakdown exactly as FR-3.2 describes, while a non-zero count
            // still can't masquerade as an iCloud deferral (FR-3.4).
            //
            // Faded at zero rather than left out, so the row keeps its place
            // in the Grid: a failure landing mid-run used to insert a line and
            // shove the Stop button below it down the card, which is exactly
            // the shift FR-8.7 forbids the app's own work from causing. Hidden
            // from VoiceOver at zero too, so it is as absent to a screen reader
            // as it looks.
            statRow("exclamationmark.triangle", .secondary, "Couldn't be analyzed", stats.failed,
                    help: "These photos were available, but the on-device analysis failed on them. Retrying downloads won't help; they're re-tried automatically when the analysis is next updated.",
                    visible: stats.failed > 0)
        }
        .font(.callout.monospacedDigit())

        // FR-8.7 allows this row to change *which* action it offers as the run
        // starts and settles — "stopping a run is rightly only on offer while
        // one is going" — on the condition that the change happens in place and
        // takes no neighbour with it. Widths may differ, then, because nothing
        // sits to the right of this row; heights may not, because the waiting
        // slot and the whole candidate grid sit below it, and the last branch
        // is a bare `Label` a button's worth of padding shorter than the other
        // three. The hidden button underneath holds the row at a button's
        // height in every branch, so the moment a run ends nothing below it
        // moves.
        ZStack(alignment: .leading) {
            Button("") {}
                .buttonStyle(.borderedProminent)
                .hidden()

            HStack {
                // FR-3.5, exactly: stopping while a run is going, resuming one
                // the user stopped, and nothing else. There is no "Analyze",
                // no "Resume" that starts a first run and no "Retry iCloud" —
                // the app starts its own work when it has some (see
                // `LibraryCatchUp`) and comes back to deferred photos itself,
                // so a button for any of those would be the app asking to be
                // told to do what it is already doing.
                if model.isRunning {
                    Button("Stop") { model.stop() }
                    // A waiting run is paused, not working: a spinner there
                    // would claim progress that isn't happening (FR-3.4's
                    // honesty rule). Faded rather than removed on each pause,
                    // so the row keeps its size across the pause/resume cycle
                    // (FR-8.7).
                    ProgressView()
                        .controlSize(.small)
                        .shownWhileWaiting(model.waitingReason == nil)
                } else if model.isStoppedByUser && remaining(stats) > 0 {
                    Button("Resume") {
                        model.start(container: modelContext.container)
                    }
                    .buttonStyle(.borderedProminent)
                } else if remaining(stats) > 0 {
                    // Work is left and nobody stopped it, so a run either
                    // failed (the message above says how — FR-8.12) or the
                    // system ended one; the app picks it up again at the next
                    // catch-up. Nothing to offer, and the hidden button behind
                    // this stack keeps the row its usual height.
                    EmptyView()
                } else {
                    Label("Analysis complete", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .help("Every scanned candidate has been analyzed; results are tallied above.")
                }
            }
        }

        // FR-3.6 / FR-3.7: when the run is deliberately holding off, say what
        // it is waiting for — right beside the Stop button that acts on it.
        //
        // Below that button rather than above it (FR-8.7). The reason a run is
        // holding off comes and goes on its own schedule — the device cools,
        // Low Power Mode ends, the network changes — and each toggle used to
        // insert or remove a line *above* the controls, so Stop hopped up and
        // down the card for as long as the pause lasted. Everything above this
        // point is now fixed in place while a run is going, and the label
        // grows downward.
        //
        // Downward is not far enough on its own, though: the candidate grid
        // sits under this card, so inserting and removing the line still moved
        // its controls every time a run paused or resumed. FR-8.7 counts this
        // as a status the app shows of its own accord while it works, so the
        // slot is reserved instead — stacked behind hidden copies of every
        // message a wait can carry, it is already as tall as the longest of
        // them before any wait starts, at whatever width and text size the
        // device is using. `shownWhileWaiting` fades the live one in on the
        // usual delay.
        ZStack(alignment: .topLeading) {
            ForEach(AnalysisWait.allCases, id: \.self) { reason in
                waitingLabel(reason.message)
                    .hidden()
            }
            waitingLabel(model.waitingReason?.message ?? "")
                .shownWhileWaiting(model.waitingReason != nil)
        }

        // FR-3.6, second half: a run that carries on unattended says where it
        // stops carrying on, instead of leaving the user to find out that the
        // sleeping Mac (or the locked phone) got nothing done — which is the
        // silent-failure FR-8.12 rules out.
        //
        // Same reserved-slot construction as the waiting label above, and for
        // the same reason: the message changes with the power source on a
        // laptop, and appears and goes as runs start and end, so the slot is
        // stacked behind hidden copies of every message it can hold and is
        // already as tall as the longest before anything runs (FR-8.7). It sits
        // last in the card so nothing but the card's own edge is below it.
        ZStack(alignment: .topLeading) {
            ForEach(UnattendedRunLimit.allCases, id: \.self) { limit in
                unattendedLimitLabel(limit)
                    .hidden()
            }
            unattendedLimitLabel(model.unattendedLimit)
                .shownWhileWaiting(model.unattendedLimit != nil)
        }
    }

    /// Secondary, not orange: this is a standing statement about the run, not
    /// something gone wrong or something being waited for, and it must not read
    /// as the more urgent of the two lines it sits under. The whole of the
    /// explanation is one hover away, where the breakdown above keeps its own.
    ///
    /// Takes the limit rather than its text so the hidden copies that reserve
    /// the slot are built exactly like the live one — nil renders the same
    /// empty label, which is what keeps the reservation honest.
    private func unattendedLimitLabel(_ limit: UnattendedRunLimit?) -> some View {
        Text(limit?.message ?? "")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .help(limit?.detail ?? "")
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func waitingLabel(_ message: String) -> some View {
        Label(message, systemImage: "pause.circle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Everything the pipeline still owes: photos never analyzed, plus the
    /// ones deferred until iCloud hands their originals over. Deferred work
    /// counts, because FR-3.4 forbids reading "complete" while it remains.
    private func remaining(_ stats: AnalysisStatistics) -> Int {
        stats.pending + stats.skipped
    }

    private func progressCaption(_ stats: AnalysisStatistics) -> String {
        // "downloading" only when downloads are actually under way: while the
        // run is waiting (device warm, or a network that doesn't allow the
        // transfer) nothing is coming down, and the waiting label under the
        // controls says what for. Claiming otherwise is exactly the false progress FR-3.4
        // rules out.
        if model.isRunning && model.waitingReason == nil && stats.pending == 0 && stats.skipped > 0 {
            "\(stats.completed) of \(stats.total) — downloading \(stats.skipped) photos from iCloud…"
        } else {
            "\(stats.completed) of \(stats.total) candidates analyzed"
        }
    }

    /// `visible` fades a row out instead of dropping it, for the one row that
    /// is conditional. It is applied to the cells rather than to the `GridRow`
    /// because a modified `GridRow` is no longer a row to `Grid` — it collapses
    /// into a single cell and takes the column alignment with it.
    private func statRow(_ symbol: String, _ color: Color, _ label: String, _ value: Int,
                         help: LocalizedStringKey, visible: Bool = true) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .foregroundStyle(color == .secondary ? Color.secondary : color)
                .help(help)
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(!visible)
            Text("\(value)")
                .gridColumnAlignment(.trailing)
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(!visible)
        }
    }
}
