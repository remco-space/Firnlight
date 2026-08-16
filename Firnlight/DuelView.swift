import SwiftUI
import SwiftData
import Observation
import CoreGraphics

/// Bumps whenever a duel choice re-trains the ranker, so ranked views know to reload.
@MainActor
@Observable
final class RankingClock {
    static let shared = RankingClock()
    private(set) var version = 0

    func bump() { version += 1 }
}

/// Drives the PreferenceRanker: prepares it, serves pairs, records choices.
@MainActor
@Observable
final class DuelModel {
    private(set) var pair: PreferenceRanker.DuelPair?
    private(set) var choiceCount = 0
    private(set) var isPreparing = false
    private(set) var isRecording = false
    /// FR-8.12: a queue, not a single slot. A single `String?` here used to
    /// let a second failure (e.g. `reload()`'s own error landing while a
    /// duel-action failure's alert was still up) silently overwrite the
    /// first — one of the two failures was never shown, which is exactly
    /// the silence the requirement forbids. Every catch block below appends;
    /// `dismissError()` pops the front, and the view's `.alert` re-presents
    /// with whatever's next as long as the queue isn't empty.
    private var errors: [String] = []
    var lastError: String? { errors.first }

    /// FR-5.12: whatever the user just told the app — a duel choice, "Both
    /// Are Great", "Both Are Bad" — can be taken back "at latest in the
    /// moment after giving it". "Not Wallpaper Material" and "Ignore This
    /// Photo" already satisfy that requirement a different way: they stay
    /// visible as a toggle in the Library tab for as long as they hold, so
    /// clearing them there (FR-4.6/4.7/4.8) is the correction path FR-5.12
    /// asks for. A raw duel choice or a "Both Are Great" verdict has no such
    /// persistent, visible mark anywhere else in the app, so the floor FR-5.12
    /// sets — correctable in the moment right after — is answered here
    /// instead: `canUndo` is true only for the single most recent action, and
    /// goes false the instant any further action (another choice, a verdict,
    /// a skip, an ignore) moves past it. Never persisted across launches, for
    /// the same reason the in-progress pair above is UI-restoration state, not
    /// durable data — the durable correction path for a *lasting* judgment
    /// stays FR-4.6's toggle.
    private(set) var canUndo = false
    private enum PendingUndo {
        case choice(PreferenceRanker.ChoiceReceipt)
        case verdict(ids: [String])
    }
    private var pendingUndo: PendingUndo?
    /// The pair that was on screen when the pending action was taken, so
    /// undoing puts the user back exactly where they were — judging it again
    /// is still valid (FR-5.10), and it is the most natural place to land
    /// after "taking back" a choice about precisely these two photos.
    private var pendingUndoPair: PreferenceRanker.DuelPair?

    private var ranker: PreferenceRanker?

    /// Set right before a bump this model itself causes (a verdict), so the
    /// resulting clock-driven `.task` re-run skips reloading the candidate
    /// snapshot the model has already advanced past. Duel *choices* no longer
    /// bump here at all — PreferenceRanker owns the bump, firing it only when
    /// its debounced cache flush actually persists new scores (see `choose`).
    private var suppressNextReload = false

    // FR-8.1: persist the in-progress duel pair so relaunching resumes on
    // exactly the same two photos instead of silently discarding whatever
    // the user was mid-way through judging. Plain `UserDefaults` (not a new
    // SwiftData model, per the task): this is UI-restoration state, not
    // durable app data — losing it just means falling back to a fresh pair,
    // never data loss (choices themselves are the durable record, FR-5.3).
    //
    // Stored as one JSON-encoded value under one key, not two separate
    // `UserDefaults.set` calls under two keys: a process kill between two
    // separate writes could leave one stale identifier under both keys
    // (including, degenerately, the same photo under both), and
    // `UserDefaults.set` for one value is the atomic unit here — there is no
    // window in which a reader can observe half of it. `PreferenceRanker.pair`
    // still guards `first != second` and liveness independently, so even a
    // still-corrupt read (e.g. an interrupted write to `duelPairKey` itself,
    // which `.atomic`-writes the whole plist file) can only ever fall back to
    // `nextPair()`, never serve a broken pair.
    private static let duelPairKey = "duelPair"
    // Superseded two-key format. Read once, as a best-effort migration for
    // anyone resuming right after upgrading, then deleted — see
    // `loadPersistedPair`. Never written again.
    private static let legacyDuelPairFirstKey = "duelPairFirst"
    private static let legacyDuelPairSecondKey = "duelPairSecond"

    private struct PersistedPair: Codable {
        let first: String
        let second: String
    }

    func start(container: ModelContainer) async {
        guard ranker == nil else { return }
        isPreparing = true
        defer { isPreparing = false }

        let ranker = PreferenceRanker(modelContainer: container)
        do {
            try await ranker.prepare()
            // Assign only after a clean prepare, so a thrown error leaves ranker
            // nil and a retry actually re-runs instead of no-opping.
            self.ranker = ranker
            choiceCount = await ranker.choiceCount
            // FR-8.1: try to resume the pair the user was looking at last
            // launch. `PreferenceRanker.pair(first:second:)` returns nil if
            // either photo is no longer a live candidate (deleted, edited
            // out, ignored, etc. — see FR-2.6/FR-4.8), in which case we just
            // fall back to a fresh pair like a normal first launch.
            if let restored = await restoredPair(ranker: ranker) {
                setPair(restored)
            } else {
                setPair(await ranker.nextPair())
            }
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    /// Refreshes the ranker's candidate snapshot (new scans, exclusions) so the
    /// duel pool isn't stale until relaunch. Advances if the visible pair now
    /// references a photo that's gone.
    func reload(container: ModelContainer) async {
        guard let ranker else {
            await start(container: container)
            return
        }
        if suppressNextReload {
            suppressNextReload = false
            return
        }
        do {
            try await ranker.reload()
            if let pair, await !ranker.contains(pair) {
                setPair(await ranker.nextPair())
            }
            // FR-5.12/FR-8.12: a pending Undo's subject can stop being a live
            // candidate while it sits on screen — ignored elsewhere, say —
            // in the gap between the choice/verdict that offered Undo and
            // this reload noticing. Leaving `canUndo` true would keep
            // offering a control that can no longer honor what it offers
            // (the ranker would just throw on the attempt); withdraw the
            // offer here instead of waiting for a doomed press to surface
            // the failure. `pendingUndoPair` names exactly the two photos
            // either a pending choice or a pending verdict concerns.
            //
            // `checkedPair` is captured before the `await` below, and the
            // live property is re-read (not just re-derived) afterward
            // rather than clearing unconditionally: `choose`/`judgeBoth` run
            // as their own concurrent `Task`s and can arm a brand-new,
            // perfectly valid pending Undo — for the same pair or a
            // different one — while this `contains` call is in flight. A
            // bare `clearPendingUndo()` after that await would blow away
            // whichever offer happens to be pending *now*, not the stale one
            // this check actually reasoned about — silently withdrawing a
            // fresh, legitimate Undo the user has every right to expect is
            // still there "at latest in the moment after giving it"
            // (FR-5.12). Only withdraw if nothing changed underneath.
            if let checkedPair = pendingUndoPair, await !ranker.contains(checkedPair),
               pendingUndoPair == checkedPair {
                clearPendingUndo()
            }
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    func choose(winner: Candidate, loser: Candidate) {
        guard !isRecording, let ranker, let shownPair = pair else { return }
        isRecording = true

        Task {
            do {
                // record() persists the choice durably and updates the ranker's
                // in-memory scores immediately; nextPair() below draws from those
                // fresh scores. The store-side preferenceScore cache is flushed on
                // a debounce inside the ranker, which bumps RankingClock once it
                // persists — so we neither write the whole library nor fan out a
                // grid/export reload here on every single choice (FR-8.2).
                let receipt = try await ranker.record(winnerID: winner.localIdentifier, loserID: loser.localIdentifier)
                choiceCount = await ranker.choiceCount
                setPendingUndo(.choice(receipt), shownPair: shownPair)
            } catch {
                errors.append(error.localizedDescription)
                clearPendingUndo()
            }
            setPair(await ranker.nextPair())
            isRecording = false
        }
    }

    func skip() {
        guard !isRecording, let ranker else { return }
        // Skip records nothing (FR-5.7), but it does move past whatever
        // preceded it — FR-5.12's window is "the moment after", and this is
        // the next moment.
        clearPendingUndo()
        Task { setPair(await ranker.nextPair()) }
    }

    /// "Both great" / "both bad": an absolute quality verdict on both photos,
    /// used to calibrate the suggested album size — then advance.
    func judgeBoth(isGood: Bool) {
        guard !isRecording, let ranker, let pair else { return }
        isRecording = true
        let shownPair = pair
        Task {
            do {
                try await ranker.recordVerdicts(
                    [shownPair.first.localIdentifier, shownPair.second.localIdentifier],
                    isGood: isGood
                )
                suppressNextReload = true // verdicts don't change the pool
                RankingClock.shared.bump() // suggestion recalibrates
                setPendingUndo(
                    .verdict(ids: [shownPair.first.localIdentifier, shownPair.second.localIdentifier]),
                    shownPair: shownPair
                )
            } catch {
                errors.append(error.localizedDescription)
                clearPendingUndo()
            }
            setPair(await ranker.nextPair())
            isRecording = false
        }
    }

    /// FR-5.12: undoes exactly the most recent choice or "Both Are
    /// Great"/"Both Are Bad" verdict, restoring the ranking to what it would
    /// have been had that judgment never been given, and re-serves the same
    /// pair the action was taken on. A no-op once nothing is pending —
    /// `canUndo` already governs whether the command is offered at all
    /// (FR-8.13: a disabled control, not a missing one, so its existence is
    /// still discoverable).
    func undo() {
        guard !isRecording, let ranker, let pendingUndo, let restorePair = pendingUndoPair else { return }
        isRecording = true
        Task {
            do {
                switch pendingUndo {
                case .choice(let receipt):
                    try await ranker.undoLastChoice(receipt)
                    choiceCount = await ranker.choiceCount
                case .verdict(let ids):
                    try await ranker.clearVerdicts(ids)
                }
                clearPendingUndo()
                suppressNextReload = true
                // Only restore the exact pair if both photos are still live
                // candidates (e.g. neither was ignored in the meantime);
                // otherwise fall back to a fresh pair rather than serving a
                // stale one (same guard `reload()` already applies).
                if await ranker.contains(restorePair) {
                    setPair(restorePair)
                } else {
                    setPair(await ranker.nextPair())
                }
            } catch {
                errors.append(error.localizedDescription)
                // FR-8.12: a failed undo took nothing back, and the offer it
                // answered can't be retried — the judgment it named either
                // never existed (`RankerError.candidateNotLive` at record
                // time slipped past an earlier check) or is already gone
                // (`RankerError.nothingToUndo`). Leaving `canUndo` true would
                // just offer the same doomed retry again.
                clearPendingUndo()
            }
            isRecording = false
        }
    }

    /// FR-8.12: dismisses the error banner currently shown, revealing the
    /// next queued one (if any) rather than clearing everything at once — a
    /// second failure that arrived while the first was still up must still
    /// get its own turn on screen, never silently discarded by the first
    /// one's dismissal. Nothing else pops `errors` — a later successful
    /// action simply leaves the queue as it was until this is called, which
    /// is fine, since the view only shows a banner while it's non-empty.
    func dismissError() {
        if !errors.isEmpty {
            errors.removeFirst()
        }
    }

    private func setPendingUndo(_ action: PendingUndo, shownPair: PreferenceRanker.DuelPair) {
        pendingUndo = action
        pendingUndoPair = shownPair
        canUndo = true
    }

    private func clearPendingUndo() {
        pendingUndo = nil
        pendingUndoPair = nil
        canUndo = false
    }

    /// Looks up the persisted pair from last launch, if any, and hands back a
    /// live `DuelPair` only if both photos are still candidates.
    private func restoredPair(ranker: PreferenceRanker) async -> PreferenceRanker.DuelPair? {
        guard let (first, second) = Self.loadPersistedPair(UserDefaults.standard) else {
            return nil
        }
        return await ranker.pair(first: first, second: second)
    }

    /// Reads the persisted in-progress pair. Prefers the current one-key
    /// format; if that is absent, falls back once to the superseded two-key
    /// format (best effort — a kill between those two old writes could still
    /// hand back a mixed or same-photo pair, which `PreferenceRanker.pair`
    /// rejects) and deletes those keys so this fallback never fires again.
    private static func loadPersistedPair(_ defaults: UserDefaults) -> (first: String, second: String)? {
        if let data = defaults.data(forKey: duelPairKey),
           let persisted = try? JSONDecoder().decode(PersistedPair.self, from: data) {
            return (persisted.first, persisted.second)
        }
        if let first = defaults.string(forKey: legacyDuelPairFirstKey),
           let second = defaults.string(forKey: legacyDuelPairSecondKey) {
            defaults.removeObject(forKey: legacyDuelPairFirstKey)
            defaults.removeObject(forKey: legacyDuelPairSecondKey)
            return (first, second)
        }
        return nil
    }

    /// Sets `pair` and keeps the persisted identifiers in lockstep: written
    /// whenever a new pair is served (covers choice/skip/verdict/ignore, all
    /// of which route through here), cleared when the pair becomes nil (no
    /// more candidates to compare) so a stale pair is never resumed. Written
    /// as one JSON value under one key — see `duelPairKey`'s doc comment for
    /// why that matters for FR-8.1's resume correctness.
    private func setPair(_ newPair: PreferenceRanker.DuelPair?) {
        pair = newPair
        let defaults = UserDefaults.standard
        if let newPair {
            let persisted = PersistedPair(first: newPair.first.localIdentifier, second: newPair.second.localIdentifier)
            if let data = try? JSONEncoder().encode(persisted) {
                defaults.set(data, forKey: Self.duelPairKey)
            }
        } else {
            defaults.removeObject(forKey: Self.duelPairKey)
        }
    }
}

/// Pairwise A/B picker: click the photo that makes the better wallpaper.
struct DuelView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model = DuelModel()

    /// The gap between the two duel cards. A named constant rather than a
    /// literal — and deliberately not in `Thresholds`, which holds tuned
    /// algorithm constants, not layout metrics — because `pairIsSideBySide`
    /// has to subtract exactly the gap the stack will insert. If the two ever
    /// drifted apart, a card could overflow the screen, which is precisely
    /// what FR-5.1 forbids.
    private static let cardSpacing: CGFloat = 16

    var body: some View {
        Group {
            if let pair = model.pair {
                VStack(spacing: 16) {
                    Text("Which makes the better wallpaper?")
                        .font(.title3.bold())

                    duelPair(pair)

                    controls
                }
                .padding(24)
            } else if model.isPreparing {
                ProgressView("Preparing ranker…")
                    .shownWhileWaiting()
            } else if let error = model.lastError {
                ContentUnavailableView("Ranker Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView(
                    "Nothing to Compare",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Firnlight is still working through your library — duels need at least two candidates.")
                )
            }
        }
        .task(id: RankingClock.shared.version) {
            // Prepares on first appearance; on later bumps (a scan/exclusion, or
            // the ranker's own debounced cache flush landing) reloads the
            // candidate snapshot so new/excluded photos show up. Coalesced to
            // flush boundaries now, not fired per choice.
            await model.reload(container: modelContext.container)
        }
        // FR-5.12/FR-8.3: published unconditionally, like every other command
        // target here, even though only the macOS Edit menu reads it back
        // (`AppCommands` itself is the thing gated to macOS) — only while
        // this tab is actually mounted, so a stale model can't let ⌘Z from
        // another tab silently act on a Duel tab the user isn't looking at.
        .focusedSceneValue(\.duelUndoTarget, model)
        // FR-8.12: a failed choice, verdict or Undo used to leave the screen
        // exactly as it looked before the press — no changed count, no
        // spinner left running, nothing said — indistinguishable from
        // success on every input route. The `else if let error` branch
        // above only ever runs once `model.pair` is nil, which it never is
        // while a mid-duel action fails (the pair only changes at the very
        // end of `choose`/`judgeBoth`/`undo`, after the failing step), so
        // that branch alone never caught this. An alert reports it instead,
        // gated on `pair != nil` so it never fires during the *other*
        // branches' own reporting (`isPreparing`'s spinner, `lastError`'s
        // `ContentUnavailableView`) — both already say their piece without
        // an alert stacked on top.
        //
        // What the alert appears over differs by which action failed:
        // `choose`/`judgeBoth` always call `setPair(await ranker.nextPair())`
        // after their catch block, success or failure alike — same as a
        // skip — so by the time the alert shows, the screen has already
        // moved on to a fresh pair; the failed pair is gone, and the alert
        // reports what happened to it a moment ago rather than sitting over
        // it. That's deliberate, not a gap: the failure means *that* pair
        // couldn't be judged as shown (typically because a photo in it
        // stopped being a candidate), so leaving it on screen would only
        // invite the same failure again. `undo`'s catch, by contrast, never
        // calls `setPair` — there is nothing valid left to advance to once
        // the correction itself failed — so its alert genuinely does sit
        // over the same pair that was on screen when Undo was pressed.
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { model.pair != nil && model.lastError != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// FR-5.1: both photos fully visible at once, however small the screen.
    /// Two `desktopAspectRatio` crops side by side form a very wide block
    /// (~32:10); the same two stacked form a very tall one (~16:20). Neither
    /// arrangement suits both a Mac window and an iPhone held upright, so the
    /// pair is laid out whichever way leaves the cards *larger* in the space
    /// actually available — side by side on the Mac, an iPad, and a phone on
    /// its side; stacked on a phone in portrait.
    ///
    /// Both cards are fully visible either way, and that is a property of the
    /// layout rather than of the arrangement chosen: each card keeps its
    /// `.fit` aspect ratio inside a `GeometryReader` that is handed only the
    /// space the surrounding `VStack` has left over after the question and the
    /// verdict row. So the cards shrink to fit rather than overflowing, and
    /// there is no scroll view for them to hide in.
    private func duelPair(_ pair: PreferenceRanker.DuelPair) -> some View {
        GeometryReader { proxy in
            let sideBySide = Self.pairIsSideBySide(in: proxy.size)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: Self.cardSpacing))
                : AnyLayout(VStackLayout(spacing: Self.cardSpacing))
            layout {
                // The position labels follow the arrangement, so VoiceOver
                // never announces "Left photo" for a card that is on top.
                DuelCard(
                    candidate: pair.first,
                    positionLabel: sideBySide ? "Left photo" : "Top photo",
                    action: { model.choose(winner: pair.first, loser: pair.second) },
                    duelModel: model
                )
                DuelCard(
                    candidate: pair.second,
                    positionLabel: sideBySide ? "Right photo" : "Bottom photo",
                    action: { model.choose(winner: pair.second, loser: pair.first) },
                    duelModel: model
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Which arrangement leaves the two fixed-shape cards bigger in `size`.
    /// A card's width is capped both by the width its share of the
    /// arrangement gets and by the height that share allows once the fixed
    /// aspect ratio is applied; whichever arrangement yields the larger cap
    /// wastes less of the space. Comparing the caps — rather than switching on
    /// size class — is what makes this right on every screen: a phone on its
    /// side is compact-width but wants the same side-by-side layout the Mac
    /// does.
    private static func pairIsSideBySide(in size: CGSize) -> Bool {
        let ratio = Thresholds.desktopAspectRatio
        let sideBySide = min((size.width - cardSpacing) / 2, size.height * ratio)
        let stacked = min(size.width, (size.height - cardSpacing) / 2 * ratio)
        return sideBySide >= stacked
    }

    /// FR-5.1's "however small the screen" covers the verdict row too: on an
    /// iPhone the three buttons and the running count do not fit on one line,
    /// and a clipped "Both Are Bad" is exactly the unreachable command FR-8.4
    /// rules out. `ViewThatFits` keeps the single row wherever it fits and
    /// moves the count to its own line where it doesn't.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            // FR-8.7: the count is mirrored by an invisible copy of itself on
            // the far side of the buttons, so the row grows by the same amount
            // at both ends and the three buttons stay exactly where they are.
            //
            // Something had to give here, because two things are true at once:
            // the buttons are centered under the cards, and the count beside
            // them gets wider at 9 → 10 and 99 → 100. Centering means half of
            // any width the count gains comes out of the buttons' position —
            // and on this screen, of all screens, the pointer is already on its
            // way to click one of them again.
            //
            // Reserving a fixed width for the count instead would need a
            // ceiling on how many duels the user may run, which there isn't;
            // left-anchoring the whole row would hold the buttons still but
            // stop them being centered, which is a redesign of a screen whose
            // symmetry is the point. A balanced mirror keeps both properties
            // and costs only the width it reserves — which is why it is
            // applied to the single-line arrangement alone. Where the row wraps
            // (an iPhone upright), the count already sits on its own line below
            // the buttons and can grow without touching them.
            HStack(spacing: 12) {
                choiceProgressRow
                    .hidden()
                    .accessibilityHidden(true)
                verdictButtons
                choiceProgressRow
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) { verdictButtons }
                choiceProgressRow
            }
        }
    }

    private var choiceProgressRow: some View {
        HStack(spacing: 8) { choiceProgress }
    }

    @ViewBuilder
    private var verdictButtons: some View {
        // No winner for the pairwise ranker, but an absolute verdict that
        // calibrates the album-size suggestion.
        Button("Both Are Great") { model.judgeBoth(isGood: true) }
            .disabled(model.isRecording)
        Button("Both Are Bad") { model.judgeBoth(isGood: false) }
            .disabled(model.isRecording)
        Button("Skip") { model.skip() }
            .disabled(model.isRecording)
        // FR-5.12: always present rather than appearing/disappearing with
        // `canUndo`, the same "always in the layout" idiom the spinner below
        // uses — an item that popped in and out here would drag the other
        // three buttons sideways under a pointer about to click one of them
        // again (FR-8.7). Disabled, not hidden, when nothing is pending: a
        // greyed command still announces that undoing is something this
        // screen can do (FR-8.13), where a missing one wouldn't.
        Button("Undo") { model.undo() }
            .disabled(model.isRecording || !model.canUndo)
            .accessibilityHint(
                model.canUndo
                    ? "Takes back your most recent choice or verdict."
                    : "Nothing to take back yet."
            )
    }

    @ViewBuilder
    private var choiceProgress: some View {
        Text("\(model.choiceCount) choices made")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        // FR-8.7, and this is the screen where it matters most: the row is
        // centered, so anything that changes its width drags the three verdict
        // buttons sideways — under a pointer that is, on this screen, about to
        // click again. The spinner is therefore always in the layout and only
        // ever fades in, and because recording a choice is a single durable
        // write it beats the delay every time in practice: the honest report
        // for work this fast is no report at all. It stays here rather than
        // being deleted for the case that isn't fast — a first write against a
        // cold store, or a device under load — where silence would look like
        // the click had been ignored.
        ProgressView()
            .controlSize(.small)
            .shownWhileWaiting(model.isRecording)
    }
}

/// One side of the duel: the photo center-cropped to the fixed desktop shape
/// (`Thresholds.desktopAspectRatio`) the wallpaper will fill, and pickable.
/// The crop is the same rectangle on every device, so the same photo wins or
/// loses on the same pixels whether the user judged it on the Mac or on a
/// phone (FR-5.1) — and it matches what the analysis measured.
private struct DuelCard: View {
    let candidate: Candidate
    /// VoiceOver label for the pick button, naming where this card actually
    /// sits: "Left"/"Right photo" side by side, "Top"/"Bottom photo" stacked.
    /// Passed in rather than derived here because only `DuelView.duelPair`
    /// knows which arrangement the available space chose (FR-5.1).
    let positionLabel: String
    let action: () -> Void
    /// Advances to a fresh pair after this photo is ignored or judged not
    /// wallpaper material (either way the current pair is spent), and is
    /// published inside `FocusedPhoto` so the menu-bar photo actions can do
    /// the same (FR-4.7/FR-4.8) — see AppCommands.swift.
    let duelModel: DuelModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var image: CGImage?
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(Thresholds.desktopAspectRatio, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // Only for a card genuinely held up (an original still
                        // coming down from iCloud). A cached image arrives
                        // faster than the delay, and a spinner blinking on
                        // every advance through the pair queue is exactly the
                        // wait FR-8.7 says not to report.
                        ProgressView()
                            .shownWhileWaiting()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            // Bound clicking/right-clicking to the visible card; a panorama's
            // scaledToFill overflow is clipped visually but not for hit-testing.
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovering ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topLeading) {
                if candidate.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .padding(4)
                        .background(.regularMaterial, in: Circle())
                        .padding(6)
                        .help("You marked this photo as a favorite in Photos, which boosts its ranking.")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.isFavorite ? "\(positionLabel), favorite" : positionLabel)
        // Ignore lives in its own button overlaid on (in front of) the pick
        // button, so its taps aren't swallowed as a duel choice.
        .overlay(alignment: .topTrailing) { ignoreButton }
        .overlay(alignment: .bottomTrailing) { actionsMenu }
        .contextMenu { photoActions }
        .onHover { isHovering = $0 }
        // Duel cards are already focusable (they're Buttons); publish the
        // focused candidate the same way ThumbnailCell does, so the Photo
        // menu (FR-4.6) reaches duel cards too. Never in "ignored" mode —
        // an ignored photo can't reach a duel pair.
        .focusedValue(\.focusedPhoto, FocusedPhoto(
            localIdentifier: candidate.localIdentifier,
            isIgnored: false,
            isNotWallpaperMaterial: candidate.isNotWallpaperMaterial,
            modelContext: modelContext,
            duelModel: duelModel
        ))
        .task(id: candidate.localIdentifier) {
            image = nil
            image = await ThumbnailLoader.load(candidate.localIdentifier, pixelSize: Thresholds.duelImagePixelSize)
        }
    }

    /// FR-5.9's visible ignore control, distinct from "Both Are Bad".
    private var ignoreButton: some View {
        Button(action: ignore) {
            Image(systemName: "eye.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Ignore \(positionLabel)")
        .help("Ignores this photo — it leaves the grid, duels, and the wallpaper album without teaching the app anything (reversible from the Library tab's Ignored view).")
    }

    /// FR-4.6's three actions, shared by the right-click menu and — on iPhone
    /// and iPad — by the visible menu button below, so both paths offer
    /// exactly the same named commands. The verdict entry is a toggle, worded
    /// as its reverse once the photo already carries it (FR-4.6); only the
    /// marking direction spends the pair (FR-4.7) — clearing a verdict
    /// mid-duel doesn't remove the photo from the pool.
    @ViewBuilder
    private var photoActions: some View {
        Button("Open in Photos") {
            CandidateActions.openInPhotos(candidate.localIdentifier, using: openURL)
        }
        Divider()
        Button(candidate.isNotWallpaperMaterial ? "Clear Verdict" : "Not Wallpaper Material") {
            let wasMarked = candidate.isNotWallpaperMaterial
            CandidateActions.setNotWallpaperMaterial(candidate.localIdentifier, !wasMarked, in: modelContext)
            if !wasMarked {
                // This pair is spent — advance (FR-4.7).
                duelModel.skip()
            }
        }
        Button("Ignore This Photo", role: .destructive) {
            ignore()
        }
    }

    /// FR-8.4 *(iPhone and iPad)*: the three actions need a home that isn't a
    /// gesture. On the Mac they already have two named ones — the right-click
    /// menu and the menu bar (FR-8.3) — so this button would be redundant
    /// chrome there and is compiled out. On touch the context menu's only
    /// trigger is a long press the user has to guess at, which FR-4.6 rules
    /// out as a sole path, so this is that path: a visible control whose menu
    /// names every action in words. It also answers FR-4.13 for the icon-only
    /// ignore button above, whose meaning is otherwise carried by a tooltip
    /// that touch never shows.
    ///
    /// Placed bottom-trailing because the other three corners are taken: the
    /// favorite heart (FR-4.4), the ignore control (FR-5.9), and the pick
    /// target itself. Overlaid on the pick button, like `ignoreButton`, so
    /// opening the menu isn't also recorded as a duel choice.
    @ViewBuilder
    private var actionsMenu: some View {
        #if !os(macOS)
        Menu {
            photoActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .padding(6)
        .accessibilityLabel("Actions for \(positionLabel)")
        #endif
    }

    private func ignore() {
        CandidateActions.ignore(candidate.localIdentifier, in: modelContext)
        duelModel.skip()
    }
}
