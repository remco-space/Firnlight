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
    /// FR-8.13: the *state* the "no pair to show" branch describes — why
    /// `start()`/`reload()` couldn't get the ranker to a servable state. A
    /// single slot, not a queue, and deliberately not the same storage the
    /// alert below reads: this is a description of the screen's current
    /// state ("Ranker Error" `ContentUnavailableView`, shown only while
    /// `pair == nil`), not a transient event to dismiss. It is replaced by
    /// whatever the next attempt finds true — cleared on a successful
    /// `prepare()`/`reload()`, and by `setPair` the moment a pair actually
    /// shows, since a pair on screen makes any earlier "why there's no pair"
    /// text stale. Without that clearing, an old, already-resolved startup
    /// error would keep being true forever, including — before this was
    /// split from the alert's queue below — replaying itself in the alert
    /// once a pair finally appeared, one dismissal at a time, over a Duel
    /// tab that had recovered.
    private(set) var stateError: String?

    /// FR-8.12: a queue, not a single slot, for a *transient* action
    /// failure (a choice, verdict, Undo, or a ranker hiccup while a pair is
    /// already showing — see `reportActionFailure`/`reportRankerFailure`). A
    /// single `String?` here used to let a second failure (e.g. `reload()`'s
    /// own error landing while a duel-action failure's alert was still up)
    /// silently overwrite the first — one of the two failures was never
    /// shown, which is exactly the silence the requirement forbids. Both
    /// `reportActionFailure` and `reportRankerFailure` append here (never
    /// `stateError`, which they may choose instead — see each); `dismissError()`
    /// pops the front, and the view's `.alert` re-presents with whatever's
    /// next as long as the queue isn't empty.
    private var errors: [String] = []
    /// What the alert shows, read fresh on every SwiftUI evaluation.
    var alertError: String? { errors.first }
    /// Guards `dismissError()` against being run twice for the same
    /// on-screen alert — see its doc comment for why a plain "queue isn't
    /// empty" check isn't enough on its own.
    private var isDismissingError = false

    /// FR-8.12/FR-8.13: routes a `start()`/`reload()` failure — the
    /// ranker's own housekeeping, run on a timer/clock bump rather than in
    /// direct response to a specific pair the user just acted on — to
    /// whichever report actually fits the screen at the moment it happened:
    /// the persistent state description while there's no pair to show
    /// anything over, or the transient, dismissible queue while there is.
    /// The same `pair == nil` test the "no pair" branch and the alert's own
    /// gate already use, so this can never disagree with which one the view
    /// is about to show. Unlike `reportActionFailure` below, `start`/`reload`
    /// have no pair of their own that failed — "is one currently on screen"
    /// really is the right question to ask about *them* specifically.
    private func reportRankerFailure(_ message: String) {
        if pair == nil {
            stateError = message
        } else {
            errors.append(message)
        }
    }

    /// FR-8.12/FR-8.13: routes a `choose`/`judgeBoth`/`undo` failure to the
    /// transient alert queue — unconditionally, never to `stateError`, and
    /// never by asking what `pair` currently is. All three only ever run in
    /// response to a specific pair that WAS on screen the moment the user
    /// pressed something (each is gated on `let shownPair = pair` or
    /// equivalent before its `Task` starts), so by construction their
    /// failure is always a transient report about a pair just acted on —
    /// never a statement about why the screen currently has none.
    ///
    /// That distinction matters because `pair` can already be nil by the
    /// time the catch block runs: the very race that fails the action — a
    /// concurrent pool refresh dropping the photo the choice/verdict/undo
    /// concerned — can also be the thing that empties the pool, so an
    /// at-that-instant `pair == nil` test (what `reportRankerFailure` uses)
    /// would misfile a one-off "that photo is no longer a candidate" message
    /// as the *persistent* reason there's nothing to compare — shown
    /// indefinitely in place of the true "Nothing to Compare" empty state,
    /// until something unrelated happens to clear it.
    private func reportActionFailure(_ message: String) {
        errors.append(message)
    }

    /// FR-5.12: whatever the user just told the app — a duel choice, "Both
    /// Are Great", "Both Are Bad" — can be taken back "at latest in the
    /// moment after giving it". "Not Wallpaper Material" and "Ignore This
    /// Photo" already satisfy that requirement a different way: they stay
    /// visible as a toggle in the Library tab for as long as they hold, so
    /// clearing them there (FR-4.6/4.7/4.8) is the correction path FR-5.12
    /// asks for. A raw duel choice or a "Both Are Great" verdict has no such
    /// persistent, visible mark anywhere else in the app, so the floor FR-5.12
    /// sets — correctable in the moment right after — is answered here
    /// instead: `canUndo` is true only for the single most recent judgment,
    /// and goes false the instant a further *judgment* (another choice, a
    /// verdict) moves past it. Only a judgment spends the moment, per
    /// FR-5.12: skipping a pair says nothing about any photo (FR-5.7) and
    /// leaves the offer standing, as does looking at another tab and back.
    /// Never persisted across launches, for
    /// the same reason the in-progress pair above is UI-restoration state, not
    /// durable data — the durable correction path for a *lasting* judgment
    /// stays FR-4.6's toggle.
    private(set) var canUndo = false
    private enum PendingUndo {
        case choice(PreferenceRanker.ChoiceReceipt)
        case verdict(PreferenceRanker.VerdictReceipt)
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
            // FR-8.13: a clean prepare retires whatever `stateError` an
            // earlier attempt left behind — it's no longer true the moment
            // this succeeds, `pair` being nil below or not.
            stateError = nil
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
            reportRankerFailure(error.localizedDescription)
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
            // FR-8.13: same reasoning as `start()` above — a successful
            // reload retires any earlier `stateError`, whether or not it
            // finds a pair to serve (a genuine "Nothing to Compare" is not
            // an error, and must not keep showing old error text either).
            stateError = nil
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
            reportRankerFailure(error.localizedDescription)
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
                reportActionFailure(error.localizedDescription)
                clearPendingUndo()
            }
            setPair(await ranker.nextPair())
            isRecording = false
        }
    }

    func skip() {
        guard !isRecording, let ranker else { return }
        // Skip deliberately leaves any pending Undo standing. It records
        // nothing (FR-5.7) — it is the user declining to judge this pair —
        // and FR-5.12 says the correction moment "is spent only by the next
        // judgment, never by the user's gaze". Passing on a pair is nearer to
        // a glance than to a judgment: it says nothing about any photo, so it
        // cannot be what supersedes the judgment before it. This used to
        // clear the offer, which meant a slipped choice followed by a reflex
        // skip — both one keystroke away in rapid judging (FR-5.11) — became
        // permanent with nothing having been said in between.
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
                let receipt = try await ranker.recordVerdicts(
                    [shownPair.first.localIdentifier, shownPair.second.localIdentifier],
                    isGood: isGood
                )
                suppressNextReload = true // verdicts don't change the pool
                RankingClock.shared.bump() // suggestion recalibrates
                setPendingUndo(.verdict(receipt), shownPair: shownPair)
            } catch {
                reportActionFailure(error.localizedDescription)
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
                case .verdict(let receipt):
                    try await ranker.undoVerdicts(receipt)
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
                reportActionFailure(error.localizedDescription)
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

    /// FR-8.12: dismisses the alert currently shown, revealing the next
    /// queued one (if any) rather than clearing everything at once — a
    /// second failure that arrived while the first was still up must still
    /// get its own turn on screen, never silently discarded by the first
    /// one's dismissal. Nothing else pops `errors` — a later successful
    /// action simply leaves the queue as it was until this is called, which
    /// is fine, since the view only shows the alert while it's non-empty.
    ///
    /// Called from exactly one place — the alert's own `isPresented`
    /// binding, whose setter SwiftUI invokes with `false` on every
    /// dismissal (including a button tap, which also runs that button's own
    /// action). The "OK" button below deliberately has an empty action and
    /// leaves the pop to the binding, not the other way around: this used to
    /// be called from both, so one tap on "OK" ran it twice — the front
    /// error that was actually shown, and the next one, silently discarded
    /// unseen (FR-8.12 again, in miniature, inside its own fix).
    ///
    /// The pop itself is deferred a runloop turn rather than done inline:
    /// mutating `errors` synchronously here, in the very call SwiftUI makes
    /// to tear the alert down, risks handing its presentation state machine
    /// a false→true flip for `isPresented` within one update, which alerts
    /// are documented by community reports to sometimes fail to re-present
    /// without a genuine dismissed frame in between. Live-verified against
    /// a real Photos library: with two failures queued, one OK dismisses the
    /// first and the second correctly re-presents, then drains.
    ///
    /// `isDismissingError` closes a second, faster race the deferral alone
    /// doesn't: a quick double dismissal (most concretely a double-click on
    /// "OK", ordinary user behavior, not an edge case) can fire this method
    /// twice before the first call's deferred `Task` has run — at that
    /// point `errors` still isn't empty, so an unguarded second call would
    /// schedule a second pop, and the two together would drain **two**
    /// messages for what the user only ever saw and dismissed as **one**
    /// alert (the second alert never had a chance to render before the
    /// second click landed on the same "OK" button). The guard treats any
    /// call arriving while a pop is already pending as redundant — the same
    /// dismissal signal restated, not a second alert genuinely dismissed —
    /// and simply drops it, so a double-click can only ever pop one message,
    /// matching the one alert the user actually acted on.
    func dismissError() {
        guard !errors.isEmpty, !isDismissingError else { return }
        isDismissingError = true
        Task { @MainActor in
            if !errors.isEmpty {
                errors.removeFirst()
            }
            isDismissingError = false
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
        // FR-8.13: a pair actually on screen makes any earlier "why there's
        // no pair" text stale. `start()`/`reload()` already clear
        // `stateError` on their own success, but every route that serves a
        // pair passes through this one method, so clearing it here too —
        // belt and suspenders — means no future call site can reintroduce
        // the stale-error replay this was written to close.
        if newPair != nil {
            stateError = nil
        }
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
    /// FR-5.12: owned by `ContentView`, not here — see its doc comment on
    /// `duelModel`. Receiving it as a plain `let` (not `@State`) is what
    /// keeps this view a pure, stateless expression of the model each time
    /// `TabView` remounts it; the model itself, and the correction offer it
    /// carries, outlives every such remount.
    let model: DuelModel

    /// FR-6.11's pattern applied to this tab: a precondition the tab cannot
    /// act without is stated as a standing fact before any attempt, not
    /// discovered from a failed press. `DuelModel` has no notion of Photos
    /// authorization at all — it only ever sees the candidates already in
    /// SwiftData — so without this, an ungranted (or since-revoked) library
    /// reads as an ordinary empty pool: "Nothing to Compare... still working
    /// through your library", a claim that's false when nothing is or ever
    /// will be working (FR-8.13: "every state the app can be in says
    /// on-screen what it means and what the user can do about it").
    /// Granting itself stays the Library tab's job alone (FR-1.2) — this
    /// only names the precondition and points there, rather than growing a
    /// second grant control that would duplicate it (FR-8.10).
    let authorization: PhotoLibraryAuthorization

    @Environment(\.modelContext) private var modelContext

    /// The gap between the two duel cards. A named constant rather than a
    /// literal — and deliberately not in `Thresholds`, which holds tuned
    /// algorithm constants, not layout metrics — because `pairIsSideBySide`
    /// has to subtract exactly the gap the stack will insert. If the two ever
    /// drifted apart, a card could overflow the screen, which is precisely
    /// what FR-5.1 forbids.
    private static let cardSpacing: CGFloat = 16

    /// FR-8.1 (HIG, tab-based apps): iPhone and iPad get a `NavigationStack`
    /// with this tab's own title, matching `LibraryTab` and `ExportView`.
    /// That `NavigationStack` sits inside `ContentView.tabContent`'s
    /// frame-and-`.clipped()`-constrained `GeometryReader` — required to
    /// keep the floating tab bar's bottom safe-area accommodation on this
    /// tab's siblings; this tab has no `ScrollView` of its own to lose it,
    /// but the wrapping is kept uniform across all three tabs. See
    /// `ContentView.tabContent`'s doc comment for the measured, reproducible
    /// SDK-27-beta bug behind it. The Mac is untouched: no bottom bar there
    /// to establish hierarchy against, and it already has its menu bar
    /// (FR-8.3).
    var body: some View {
        #if os(macOS)
        duelContent
        #else
        NavigationStack {
            duelContent
                .navigationTitle("Duel")
        }
        #endif
    }

    private var duelContent: some View {
        Group {
            if !authorization.isAuthorized {
                ContentUnavailableView(
                    "Photos Access Needed",
                    systemImage: "lock.rectangle",
                    description: Text("Firnlight needs access to your whole Photos library before it can compare photos. Grant access from the Library tab.")
                )
            } else if let pair = model.pair {
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
            } else if let error = model.stateError {
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
            // FR-6.11's pattern again: no attempt at all while the
            // precondition doesn't hold, not just a different message over
            // a no-op one. `authorization.isAuthorized` flipping is exactly
            // what re-runs `RankingClock`-independent work here too, since
            // `ContentView`'s own `.task(id: authorization.isAuthorized)`
            // kicks the library pipeline the moment access is granted,
            // which eventually bumps `RankingClock` once candidates exist —
            // this task doesn't need its own separate trigger.
            guard authorization.isAuthorized else { return }
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
        // that branch alone never caught this. An alert reports it instead.
        // `model.alertError` is a wholly separate queue from `stateError`
        // (see `DuelModel`'s `reportRankerFailure`/`reportActionFailure`): a
        // `choose`/`judgeBoth`/`undo` failure always lands here, regardless
        // of what `pair` happens to be by the time its catch runs, and a
        // `start`/`reload` failure caught while there was no pair to show
        // anything over goes to `stateError` instead — never in this queue
        // to begin with, so it can never resurface here once a pair finally
        // appears.
        //
        // Gated on `model.alertError != nil` alone now — NOT also on
        // `model.pair != nil`, which this used to require. That gate was
        // reasoned (wrongly) on an assumption that by the time the alert
        // shows, `choose`/`judgeBoth` have always already called
        // `setPair(await ranker.nextPair())` and landed on a fresh pair —
        // true only while the pool still has one to give. When the same
        // failure that emptied the pair (a photo the failing pair depended
        // on stopped being a candidate) also exhausts it, `nextPair()`
        // legitimately returns nil: the queued failure and a nil `pair` can
        // coexist, and reporting either the `stateError` panel or "Nothing
        // to Compare" instead of the alert would silently drop the
        // just-recorded failure — exactly the silence FR-8.12 forbids, and
        // exactly the gap validation found: an error could sit queued
        // forever behind a `pair == nil` screen that never mentions it
        // (reload() can also null a displayed `pair` out from under a
        // pending alert on its own bump-driven `Task`, same effect). An
        // alert stacking momentarily over `isPreparing`'s spinner or
        // `stateError`'s `ContentUnavailableView` is a strictly better
        // outcome than the message never appearing — SwiftUI's `.alert` is
        // a modal presentation, not a layout element, so there is nothing
        // for it to visually collide with underneath (FR-8.11 doesn't
        // apply to a sheet floating above the whole screen).
        //
        // What the alert appears over now genuinely varies, and that's
        // fine: often a fresh pair (the common case above), sometimes the
        // `stateError`/"Nothing to Compare" screen if the pool ran out in
        // the same stroke, and for `undo`'s catch — which never calls
        // `setPair`, since there is nothing valid to advance to once the
        // correction itself failed — always the same pair that was on
        // screen when Undo was pressed.
        //
        // The "OK" button's action is deliberately empty — see
        // `dismissError()`'s doc comment for why calling it from both here
        // and the binding's setter double-popped the queue.
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { model.alertError != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(model.alertError ?? "")
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

    /// FR-8.1 (HIG: "using the platform's own controls" — give a button
    /// chrome matching its importance, and make interactivity visually
    /// apparent): left unstyled, `Button`'s `.automatic` style resolves
    /// per-platform to two different things for the exact same row. On
    /// macOS it's the standard bordered push button — fine, and every
    /// other screen's persistent action already looks like this. On
    /// iPhone/iPad `.automatic` in this plain context resolves to
    /// tint-only text with no border or background: nothing here marks
    /// four persistent, always-visible commands as tappable buttons rather
    /// than static labels. `.bordered` fixes iOS/iPadOS without changing
    /// macOS's existing look (macOS's own `.automatic` push-button chrome
    /// and `.bordered` render the same there), and none of the four is
    /// `.borderedProminent` — the two duel cards above are already this
    /// screen's one prominent action (FR-8.5's cap), and this row is
    /// deliberately secondary to them.
    @ViewBuilder
    private var verdictButtons: some View {
        Group {
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
        .buttonStyle(.bordered)
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

    /// FR-8.1: Apple's own Liquid Glass guidance treats sharing a
    /// `GlassEffectContainer` across nearby glass surfaces as correctness,
    /// not polish — glass cannot sample other glass, so elements close
    /// enough to interfere need one shared container to render and blend
    /// correctly. This card carries three independent glass surfaces (the
    /// favorite badge, the ignore control, the actions menu), so all three
    /// share one container rather than each calling `.glassEffect()` in
    /// isolation.
    private static let glassContainerSpacing: CGFloat = 16

    var body: some View {
        GlassEffectContainer(spacing: Self.glassContainerSpacing) {
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
                            // Only for a card genuinely held up (an original
                            // still coming down from iCloud). A cached image
                            // arrives faster than the delay, and a spinner
                            // blinking on every advance through the pair
                            // queue is exactly the wait FR-8.7 says not to
                            // report.
                            ProgressView()
                                .shownWhileWaiting()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                // Bound clicking/right-clicking to the visible card; a
                // panorama's scaledToFill overflow is clipped visually but
                // not for hit-testing.
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isHovering ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topLeading) {
                    if candidate.isFavorite {
                        // FR-8.5: floating over the photo doesn't make this
                        // the photo's own plain surface — it's the app's own
                        // status badge, so it wears the platform's real
                        // glass rather than a hand-built material imitation
                        // of it, exactly like the ignore control and actions
                        // menu below.
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .padding(4)
                            .glassEffect(in: .circle)
                            .padding(6)
                            .help("You marked this photo as a favorite in Photos, which boosts its ranking.")
                            // FR-8.13/FR-4.13: the heart's meaning ("marked a
                            // favorite in Photos, boosts its ranking") used to
                            // live only in `.help()`, a route touch and
                            // VoiceOver users never reach. The hint carries
                            // the same words through the route that does
                            // reach them, alongside `.help()` for pointer
                            // users — see `ignoreButton` below for the same
                            // pairing on a pressable control.
                            .accessibilityHint("Marked as a favorite in Photos, which boosts its ranking.")
                    }
                }
            }
            .buttonStyle(.plain)
            // FR-8.12: a press mid-recording would silently no-op against
            // `DuelModel.choose`'s own `!isRecording` guard — the control
            // would still look pickable while doing nothing, exactly what
            // "a control that offers itself as available does what it
            // offers" forbids. Same reasoning covers `ignoreButton` and the
            // duel-state entries in `photoActions` below.
            .disabled(duelModel.isRecording)
            .accessibilityLabel(candidate.isFavorite ? "\(positionLabel), favorite" : positionLabel)
            // Ignore lives in its own button overlaid on (in front of) the
            // pick button, so its taps aren't swallowed as a duel choice.
            .overlay(alignment: .topTrailing) { ignoreButton }
            .overlay(alignment: .bottomTrailing) { actionsMenu }
        }
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
    /// FR-8.5: this is one of the app's own controls, floating over the
    /// photo rather than belonging to it, so it wears the platform's real
    /// glass (`.glassEffect(.regular.interactive())`), never a hand-built
    /// `.background(.regularMaterial)` imitation of it — only the
    /// photograph itself stays plain. `.interactive()` because this is a
    /// pressable control, not a static badge (contrast the favorite heart
    /// above). Shares `body`'s `GlassEffectContainer` with the favorite
    /// badge and the actions menu (FR-8.1) rather than rendering in
    /// isolation.
    private var ignoreButton: some View {
        Button(action: ignore) {
            Image(systemName: "eye.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(6)
        // FR-8.12: see the pick button's own `.disabled` comment above — a
        // press mid-recording would silently no-op against `DuelModel.skip`'s
        // own `!isRecording` guard.
        .disabled(duelModel.isRecording)
        .accessibilityLabel("Ignore \(positionLabel)")
        .help("Ignores this photo — it leaves the grid, duels, and the wallpaper album without teaching the app anything (reversible from the Library tab's Ignored view).")
        // FR-8.13/FR-4.13: how this differs in consequence from "Both Are
        // Bad" (FR-5.9) — removal versus a quality judgment the ranking
        // learns from — used to be explained only in the `.help()` tooltip
        // above, a route pointer users get and touch/VoiceOver users never
        // do. The hint restates the same distinction through the route that
        // reaches them, so the difference is discoverable before the act on
        // every platform, not just under a mouse.
        .accessibilityHint("Removes this photo from the grid, duels, and the wallpaper album without teaching the app anything — unlike Both Are Bad, which keeps it and marks it as a quality judgment.")
    }

    /// FR-4.6's three actions, shared by the right-click menu and — on iPhone
    /// and iPad — by the visible menu button below, so both paths offer
    /// exactly the same named commands. The verdict entry is a toggle, worded
    /// as its reverse once the photo already carries it (FR-4.6); only the
    /// marking direction spends the pair (FR-4.7) — clearing a verdict
    /// mid-duel doesn't remove the photo from the pool.
    ///
    /// FR-8.13/FR-4.13: the two verdict entries below, and the favorite row
    /// when present, put a second `Text` in the `Button`'s own `label` —
    /// SwiftUI renders that as a visible subtitle line under the row's
    /// title in a `Menu`/context menu, not a tooltip. That gives a sighted
    /// user with neither a pointer (no `.help()`) nor VoiceOver (no
    /// accessibility hint) an on-screen route to "how it differs in
    /// consequence from its neighbours" (FR-4.7 vs FR-4.8 above all) —
    /// reachable as this row's own named command (FR-4.13), on every
    /// platform, since this same `photoActions` backs both the Mac's
    /// right-click menu and touch's `actionsMenu` below. The title
    /// (`Text`'s first line) still only ever states the act — never the
    /// consequence, per FR-8.13 — the subtitle carries the consequence
    /// instead.
    @ViewBuilder
    private var photoActions: some View {
        // Never disabled: opening the photo in Photos doesn't touch
        // `duelModel` at all, so it stays available through a duel action
        // in flight (FR-8.12 only requires disabling what would actually
        // no-op).
        Button("Open in Photos") {
            CandidateActions.openInPhotos(candidate.localIdentifier, using: openURL)
        }
        if candidate.isFavorite {
            Divider()
            // A disabled, action-less row: purely informational, the same
            // route as the two verdict rows below but with nothing to do —
            // the favorite heart badge is a status indicator, not a
            // control, so there's no act to name here, only the
            // consequence FR-4.13 requires be discoverable somewhere other
            // than `.help()`.
            Button {} label: {
                Text("Favorite in Photos")
                Text("Boosts this photo's ranking.")
            }
            .disabled(true)
        }
        Divider()
        // FR-8.12: both entries below end in `duelModel.skip()`, which
        // no-ops under its own `!isRecording` guard — same reasoning as the
        // pick button and `ignoreButton` above.
        Button {
            let wasMarked = candidate.isNotWallpaperMaterial
            CandidateActions.setNotWallpaperMaterial(candidate.localIdentifier, !wasMarked, in: modelContext)
            if !wasMarked {
                // This pair is spent — advance (FR-4.7).
                duelModel.skip()
            }
        } label: {
            Text(candidate.isNotWallpaperMaterial ? "Clear Verdict" : "Not Wallpaper Material")
            Text(
                candidate.isNotWallpaperMaterial
                    ? "Returns this photo to normal standing."
                    : "A quality judgment the app learns from — it stays in the ranking but sinks over time."
            )
        }
        .disabled(duelModel.isRecording)
        Button(role: .destructive) {
            ignore()
        } label: {
            Text("Ignore This Photo")
            Text("Removes it from the grid, duels, and the album without teaching the app anything — unlike Both Are Bad, which keeps it as a quality judgment.")
        }
        .disabled(duelModel.isRecording)
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
    /// FR-8.5: same reasoning as `ignoreButton` above — the app's own
    /// control floating over the photo, so it wears real glass rather than
    /// a `.background(.regularMaterial)` stand-in.
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
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(6)
        .accessibilityLabel("Actions for \(positionLabel)")
        #endif
    }

    private func ignore() {
        CandidateActions.ignore(candidate.localIdentifier, in: modelContext)
        duelModel.skip()
    }
}
