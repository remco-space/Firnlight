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
    /// Non-nil while the run is alive but deliberately not working — the
    /// device is warm or on battery-saving terms (FR-3.6), or iCloud downloads
    /// are the only work left and the network doesn't allow them (FR-3.7).
    /// The run stays running: this is a pause the user can see and stop, not
    /// a silent stall.
    private(set) var waitingReason: AnalysisWait?

    private var queue: AnalysisQueue?
    private var runTask: Task<Void, Never>?

    func refresh(container: ModelContainer) async {
        stats = try? await ensureQueue(container).statistics()
    }

    /// Starts the batch loop if idle and returns the running task, so callers
    /// that must await completion (the startup auto-resync) can, while the
    /// manual button ignores the result. Re-entry while running returns the
    /// in-flight task, so a user click and the auto-resync never double-run.
    ///
    /// This is where FR-3.6 *(iPhone and iPad)* is implemented in full: the
    /// user starts a run here, can stop it at any moment, it pauses with a
    /// stated reason when the device is warm or saving power (see
    /// `RunConditions`), and it asks the system to keep going once the app
    /// leaves the foreground (`ContinuedAnalysisTask`).
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
        if let runTask, isRunning { return runTask }
        // A previous run may still be finishing its rescore (it clears
        // `isRunning` before that, so the guard above lets us through). Hold on
        // to it and wait for it below rather than starting on top of it.
        let previousRun = runTask
        isRunning = true
        lastError = nil
        let queue = ensureQueue(container)

        #if os(iOS)
        // FR-3.6: ask the system to let this run continue once the app is no
        // longer on screen. Best-effort by construction — if it is refused the
        // loop below is unchanged and simply only advances in the foreground.
        // The shared owner, not a fresh one per run: see ContinuedAnalysisTask.
        let continued = ContinuedAnalysisTask.shared
        Task { await continued.begin(onCancel: { [weak self] in self?.stop() }) }
        #endif

        let task = Task {
            // Never two rescores at once: both write the weights file and the
            // whole preference-score cache.
            await previousRun?.value
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
                        try await Task.sleep(for: Thresholds.analysisPauseRecheckInterval)
                        continue
                    }

                    // FR-3.7: only ask PhotoKit to download originals when the
                    // user's network settings allow it.
                    let networkWait = RunConditions.iCloudDownloadWait
                    waitingReason = nil

                    guard let processed = try await queue.processNextBatch(allowNetworkDownloads: networkWait == nil),
                          processed > 0 else {
                        let current = try await queue.statistics()
                        stats = current
                        // Local work is done. If the only thing left is
                        // deferred iCloud records that the network is holding
                        // back, that is a wait, not completion — FR-3.4 is
                        // explicit that the app never claims to be finished
                        // while deferred work remains.
                        if let networkWait, current.skipped > 0 {
                            waitingReason = networkWait
                            try await Task.sleep(for: Thresholds.analysisPauseRecheckInterval)
                            continue
                        }
                        break
                    }
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
                lastError = error.localizedDescription
            }
            #if os(iOS)
            continued.end(success: lastError == nil)
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

    /// Stops after the in-flight batch; progress is already saved per batch.
    ///
    /// Cancels but deliberately does **not** clear `runTask`: the task lives on
    /// through its rescore, and `start` chains the next run onto it. Clearing
    /// it here would defeat that — the re-entry guard reads `runTask`, so a
    /// quick Stop → Analyze would slip past it and run two `prepare()`s at once,
    /// both writing the weights file and the score cache.
    func stop() {
        runTask?.cancel()
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
                        Text("Scan the library first — analysis runs on the candidates it finds.")
                            .foregroundStyle(.secondary)
                    } else {
                        content(stats)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
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
            // modifier is on `ScanView`'s content so the two stay equal.
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

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            statRow("checkmark.seal", .green, "Wallpaper candidates", stats.accepted,
                    help: "Photos that passed every analysis check and compete for the wallpaper album.")
            statRow("person.2.slash", .secondary, "People", stats.people,
                    help: "Rejected: people were detected in these photos.")
            statRow("doc.viewfinder", .secondary, "Utility images", stats.utility,
                    help: "Rejected: these look like documents, screenshots, or other utility images.")
            // Plain leaf: the row label carries the negation (no leaf.slash
            // exists, and the arrow variant is the recycling symbol).
            statRow("leaf", .secondary, "Not nature", stats.notNature,
                    help: "Rejected: these don't look like nature scenes.")
            statRow("icloud.and.arrow.down", .orange, "iCloud (deferred)", stats.skipped,
                    help: "Skipped for now: the originals are in iCloud and not downloaded; retrying fetches and analyzes them.")
            // Only shown when there is something to report. FR-3.2 fixes the
            // set-aside reasons the user is offered, and this isn't one of
            // them — it's the app admitting it couldn't look, rather than a
            // judgment about the photo. Hiding it at zero keeps the normal
            // breakdown exactly as FR-3.2 describes, while a non-zero count
            // still can't masquerade as an iCloud deferral (FR-3.4).
            if stats.failed > 0 {
                statRow("exclamationmark.triangle", .secondary, "Couldn't be analyzed", stats.failed,
                        help: "These photos were available, but the on-device analysis failed on them. Retrying downloads won't help; they're re-tried automatically when the analysis is next updated.")
            }
        }
        .font(.callout.monospacedDigit())

        // FR-3.6 / FR-3.7: when the run is deliberately holding off, say what
        // it is waiting for. Placed above the controls so it sits next to the
        // Stop button that acts on it.
        if let waiting = model.waitingReason {
            Label(waiting.message, systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            if model.isRunning {
                Button("Stop") { model.stop() }
                // A waiting run is paused, not working: a spinner there would
                // claim progress that isn't happening (FR-3.4's honesty rule).
                if model.waitingReason == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if stats.pending > 0 {
                Button(stats.analyzed == 0 ? "Analyze \(stats.pending) Photos" : "Resume (\(stats.pending) remaining)") {
                    model.start(container: modelContext.container)
                }
                .buttonStyle(.borderedProminent)
            } else if stats.skipped > 0 {
                Button("Retry \(stats.skipped) iCloud Photos") {
                    model.start(container: modelContext.container)
                }
            } else {
                Label("Analysis complete", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .help("Every scanned candidate has been analyzed; results are tallied above.")
            }
        }
    }

    private func progressCaption(_ stats: AnalysisStatistics) -> String {
        // "downloading" only when downloads are actually under way: while the
        // run is waiting (device warm, or a network that doesn't allow the
        // transfer) nothing is coming down, and the waiting label above says
        // what for. Claiming otherwise is exactly the false progress FR-3.4
        // rules out.
        if model.isRunning && model.waitingReason == nil && stats.pending == 0 && stats.skipped > 0 {
            "\(stats.completed) of \(stats.total) — downloading \(stats.skipped) photos from iCloud…"
        } else {
            "\(stats.completed) of \(stats.total) candidates analyzed"
        }
    }

    private func statRow(_ symbol: String, _ color: Color, _ label: String, _ value: Int, help: LocalizedStringKey) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .foregroundStyle(color == .secondary ? Color.secondary : color)
                .help(help)
            Text("\(value)")
                .gridColumnAlignment(.trailing)
        }
    }
}
