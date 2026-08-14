import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Export tab's state and sync logic. Hoisted into an `@Observable` model
/// (matching `GridModel`/`DuelModel`/`AnalysisModel` elsewhere) rather than
/// left as view-local `@State`, specifically so the menu bar's "Sync Album"
/// command (FR-8.3) can trigger the same sync and read the same
/// `isSyncing`/`canSync` state the button does — see
/// `.focusedSceneValue(\.exportCommandTarget, ...)` on `ExportView` below,
/// and `AppCommands.swift` for how the command reads it back.
@MainActor
@Observable
final class ExportModel {
    /// FR-6.4's suggested count — where quality drops off in the user's own
    /// ranking. nil until the first one has been computed.
    private(set) var suggestion: Int?
    private(set) var preview: [Candidate] = []
    /// nil until the first `albumCandidates` load completes; the size scale
    /// has no honest ceiling before then, so the controls stay disabled.
    private(set) var totalAccepted: Int?
    private(set) var isSyncing = false
    private(set) var outcome: WallpaperAlbumSync.Outcome?
    private(set) var errorMessage: String?
    /// FR-6.11: a sync found no album this device can see. Held as its own
    /// state rather than folded into `errorMessage`, because it isn't an
    /// error — it's a wait, with one thing the user may legitimately want to
    /// do about it (create the album, if this is the first device).
    private(set) var albumMissing = false
    /// FR-6.8: a previous sync died partway and the album is still mid-rebuild.
    /// Offered rather than repaired automatically — the devices share one
    /// album, so an unattended restore could undo a deliberate sync made on
    /// another one (FR-6.10). See `WallpaperAlbumSync.restoreInterruptedSync`.
    private(set) var hasInterruptedSync = false
    private(set) var isRestoring = false
    /// One reused model actor (and its ModelContext) for both reload tasks.
    /// Spinning up a fresh FeatureStore per keystroke/re-rank churned contexts
    /// against the store; `.task(id:)` already cancels a superseded run, so a
    /// stable store coalesces Export's two loads the way GridModel coalesces the
    /// grid's — the second half of taming the per-choice fan-out (FR-8.2).
    private var store: FeatureStore?

    /// FR-1.9: the change waiting on the user's answer, if any. The sync that
    /// asked is suspended until `answerPendingChange` resumes it — see
    /// `PendingPhotosChange`.
    private(set) var pendingChange: PendingPhotosChange?

    /// Serializes `confirm` so `pendingChange` is never overwritten out from
    /// under a caller still waiting on it.
    ///
    /// Sync, Restore and Create Album each run as their own `Task` and each
    /// calls `confirm`, and nothing before this stopped two from being in
    /// flight together — Create Album has no `.disabled` guard at all, and the
    /// menu bar's "Sync Album" reads `canSync`, which never looked at
    /// `isRestoring`. A second call used to overwrite `pendingChange` outright,
    /// stranding the first caller's continuation forever: its `Task` never
    /// resumed, so `isSyncing`/`isRestoring` for that operation never cleared
    /// and its button stayed dead for the rest of the session. Queuing here
    /// instead means a second question waits its turn — displayed the moment
    /// the first is answered — so no caller can ever be left unresumed by
    /// another one asking.
    private var askers: [CheckedContinuation<Void, Never>] = []
    private var isAsking = false

    func refreshAccess() {
        hasInterruptedSync = WallpaperAlbumSync.hasInterruptedSync
    }

    /// FR-1.9's ask, in the form the write path calls it: hand over the change
    /// about to be made, get back whether it may happen. Returns `true`
    /// immediately for a kind of change the user has told the app to stop
    /// asking about — the switch in Settings is what turns asking back on.
    ///
    /// `@Sendable` and `nonisolated`-friendly by construction: it is passed to
    /// `WallpaperAlbumSync`, which is not on the main actor, and awaiting a
    /// main-actor method from there is the hop that gets the question onto the
    /// screen.
    func confirm(_ change: PhotosChange) async -> Bool {
        guard PhotosChangeConsent.shouldAsk(change.kind) else { return true }
        await claimTurn()
        defer { releaseTurn() }
        return await withCheckedContinuation { continuation in
            pendingChange = PendingPhotosChange(change: change) { answer in
                continuation.resume(returning: answer)
            }
        }
    }

    /// Waits until no other call owns `pendingChange`, then claims it.
    private func claimTurn() async {
        if !isAsking {
            isAsking = true
            return
        }
        await withCheckedContinuation { continuation in
            askers.append(continuation)
        }
    }

    /// Hands the turn to the next waiting call, if any — resuming it is what
    /// puts its question on screen.
    private func releaseTurn() {
        guard !askers.isEmpty else {
            isAsking = false
            return
        }
        askers.removeFirst().resume()
    }

    /// The alert's answer. `remember` is FR-1.9's "turn off asking for this
    /// kind of change from the alert itself", and it only ever accompanies a
    /// yes: there is no way to permanently decline, because a change nobody
    /// wants is simply not asked for again.
    func answerPendingChange(approve: Bool, remember: Bool = false) {
        guard let pending = pendingChange else { return }
        // Cleared before resuming, so the resumed sync can't observe a change
        // that has already been answered.
        pendingChange = nil
        if approve && remember {
            PhotosChangeConsent.setShouldAsk(pending.change.kind, false)
        }
        pending.resume(approve)
    }

    /// FR-6.8, on the user's say-so: put the album back the way the
    /// interrupted sync found it.
    ///
    /// It reports no error of its own, so it has nothing to put in the place
    /// of one already on screen and leaves it standing — see `sync` for why
    /// clearing it up front is not allowed.
    func restoreInterruptedSync() {
        isRestoring = true
        Task {
            await WallpaperAlbumSync.restoreInterruptedSync(confirm: { [weak self] change in
                guard let self else { return false }
                return await self.confirm(change)
            })
            hasInterruptedSync = WallpaperAlbumSync.hasInterruptedSync
            isRestoring = false
        }
    }

    /// Whether "Sync Album" (button or menu command) has anything to do
    /// right now. Also stands in for "not authorized" in the menu command's
    /// disabled state: without access to the whole library (FR-1.8) nothing is
    /// scanned, so the candidate pool is empty, `totalAccepted` never rises
    /// above 0 and this reads false without needing its own authorization
    /// plumbing.
    ///
    /// `!isRestoring` too: the menu command has no other way to see that a
    /// restore's consent alert is up, and starting a sync underneath it would
    /// be a second Photos-album write racing the first.
    var canSync: Bool { !isSyncing && !isRestoring && (totalAccepted ?? 0) > 0 }

    /// Whether the size control has both numbers it needs to mean anything:
    /// the app's suggestion (which the choice is held relative to) and the
    /// real size of the candidate pool (the scale's ceiling). FR-6.5 wants a
    /// loading state rather than a made-up count, and a slider drawn before
    /// either number arrives would be exactly that.
    var isReady: Bool { suggestion != nil && totalAccepted != nil }

    /// FR-6.3's ends: "a handful of photos" at one, "every candidate the
    /// library holds" at the other.
    ///
    /// A library with fewer photos than a handful collapses the two, which is
    /// left to `AlbumSizeScale` to survive rather than special-cased here —
    /// there is no album size to pick when the pool is smaller than the
    /// smallest album, and the control is disabled for it.
    var largestSize: Int { max(1, totalAccepted ?? Thresholds.defaultWallpaperCount) }
    var smallestSize: Int { min(Thresholds.minimumWallpaperCount, largestSize) }

    /// FR-6.12, the whole of it: what the app remembers is not a count but the
    /// user's standard relative to its own suggestion — 1.0 meaning "as many
    /// as you think", 0.5 "half as many as you think".
    ///
    /// Holding the ratio rather than the number is what makes the count track
    /// a suggestion that moves with new analysis and judgments, and it is also
    /// how FR-6.4's "followed automatically until the user first moves the
    /// slider" falls out with no flag to keep: an untouched control is a ratio
    /// of exactly 1, which *is* the suggestion, every time it changes. Moving
    /// the slider is the only thing that writes a different one, and from then
    /// on the suggestion never overrides it.
    ///
    /// `UserDefaults` because it must survive a relaunch (FR-7.1) and there is
    /// no shared store to sync it through — the album is shared between the
    /// user's devices, but this is a preference about it, not part of it.
    /// `double(forKey:)` reads 0 for a key that was never written, and 0 is
    /// not a ratio any choice can produce, so it doubles as "never set".
    ///
    /// Not `private`, and `nonisolated`: `JudgmentArchive` reads and writes
    /// this same key directly (FR-7.4, FR-6.12) so a copy of the judgments
    /// carries the standard too, and restoring one merges it back, from
    /// `@concurrent` code that cannot touch this `@MainActor` class's
    /// isolated members. A `String` literal is immutable and `Sendable`, so
    /// opting it out of isolation is safe. One key literal, named once, is
    /// what keeps the two from silently drifting apart.
    nonisolated static let strictnessDefaultsKey = "WallpaperAlbum.sizeStrictness"

    private var strictness: Double = {
        let stored = UserDefaults.standard.double(forKey: ExportModel.strictnessDefaultsKey)
        return stored > 0 ? stored : 1
    }() {
        // Not while a drag is in flight: a slider writes its binding on every
        // frame, and the only ratio worth keeping is the one the user let go
        // on. `isAdjustingSize` writes it then.
        didSet {
            if !isAdjustingSize { persistStrictness() }
        }
    }

    private func persistStrictness() {
        UserDefaults.standard.set(strictness, forKey: Self.strictnessDefaultsKey)
    }

    /// The suggestion the ratio is measured against. Before the first one
    /// arrives this stands in for it, so the preview has a limit to load with
    /// and the pool's real size can be learned; `isReady` keeps that
    /// provisional number off the screen in the meantime (FR-6.5).
    private var suggestionBase: Int { max(1, suggestion ?? Thresholds.defaultWallpaperCount) }

    /// FR-6.3's exact count — what the number field shows, what a sync uses,
    /// and the only count the rest of the app knows about.
    ///
    /// Derived rather than stored, because FR-6.12 makes the ratio the thing
    /// the app remembers: the count is simply the suggestion scaled by it, and
    /// so moves whenever the suggestion does. Writing to it — from the slider
    /// or the number field, the only two ways FR-6.3 gives the user — records
    /// a new ratio; that is the only way one is ever written.
    var count: Int {
        get { clampedToPool(Int((Double(suggestionBase) * strictness).rounded())) }
        set { strictness = Double(clampedToPool(newValue)) / Double(suggestionBase) }
    }

    /// Clamping lives on the read side so that a ratio set against a large
    /// library is not quietly rewritten by a moment when the pool looked
    /// small — the user's standard is remembered as they expressed it, and
    /// only what is shown is held to what the library can actually supply.
    private func clampedToPool(_ value: Int) -> Int {
        min(max(value, smallestSize), largestSize)
    }

    /// Whether the user has hold of the size slider at this moment.
    ///
    /// Two things must not happen under a thumb somebody is dragging, and this
    /// is what holds both off. The scale must not be rebuilt beneath it: the
    /// track's far end is the size of the candidate pool, which keeps growing
    /// while analysis runs, and every photo it gains slides the thumb — the
    /// grab target itself — with no act of the user's behind it (FR-8.7). And
    /// the preview must not be rebuilt from every count the drag passes
    /// through: that is a query across the whole pool per frame, and a grid
    /// reflow behind it, which is the shape of work FR-8.2 exists to keep out
    /// of the interface's way. Both resume the moment the thumb is let go.
    var isAdjustingSize = false {
        didSet {
            guard !isAdjustingSize else { return }
            refreshSizeScale()
            persistStrictness()
        }
    }

    /// The scale the slider is drawn on. Stored rather than derived from the
    /// pool precisely so it can be held still — see `isAdjustingSize`. The
    /// value it starts at is never shown: `isReady` is false until the first
    /// real one replaces it.
    private(set) var sizeScale = AlbumSizeScale(
        smallest: Thresholds.minimumWallpaperCount,
        largest: Thresholds.defaultWallpaperCount
    )

    /// The suggestion as the slider currently marks it — held still with the
    /// scale, and for the same reason.
    private(set) var markedSuggestion: Int?

    private func refreshSizeScale() {
        guard !isAdjustingSize else { return }
        sizeScale = AlbumSizeScale(smallest: smallestSize, largest: largestSize)
        markedSuggestion = suggestion
    }

    /// The slider's own value: FR-6.3's count, in the log space that makes the
    /// scale proportional. See `AlbumSizeScale`.
    /// How wide the slider is drawn, as the view last measured it. Held here
    /// only so the detent below can be expressed as a distance on screen
    /// rather than a share of the track — see `AlbumSizeScale.detented`.
    var trackWidth: CGFloat = 0

    var sizePosition: Double {
        get { sizeScale.position(of: count) }
        set {
            count = sizeScale.count(at: sizeScale.detented(
                newValue,
                toward: markedSuggestion,
                reach: detentReach
            ))
        }
    }

    /// `Thresholds.albumSizeDetentReach` converted from points into the
    /// scale's units. Zero until the track has been measured, which switches
    /// the catch off rather than guessing at it — there is nothing to adopt
    /// before the control has been drawn.
    private var detentReach: Double {
        let usable = trackWidth - Thresholds.sliderTrackInset * 2
        guard usable > 0 else { return 0 }
        let span = sizeScale.bounds.upperBound - sizeScale.bounds.lowerBound
        return span * Double(Thresholds.albumSizeDetentReach / usable)
    }

    /// FR-6.4: recompute whenever the ranking moves. Nothing here adopts
    /// anything — with the choice held as a ratio (see `strictness`), a fresh
    /// suggestion carries the count with it automatically for a user who has
    /// never moved the slider, and equally automatically leaves the standard
    /// of one who has.
    func refreshSuggestion(container: ModelContainer) async {
        do {
            suggestion = try await featureStore(container).suggestedAlbumSize()
            reloadStrictnessIfChanged()
            refreshSizeScale()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Picks up a standard `JudgmentArchive.restore` may just have adopted
    /// (FR-6.12, FR-7.4). A restore writes `UserDefaults` directly rather
    /// than through this model — it runs `@concurrent`, off this
    /// `@MainActor` instance, and may run before the instance even exists —
    /// so an already-open Export tab would otherwise keep showing the
    /// standard it launched with until relaunch. Piggybacking on this
    /// refresh, rather than adding a second notification path for one value,
    /// works because `SettingsView.restoreJudgments` already calls
    /// `RankingClock.shared.bump()`, which is what re-invokes
    /// `refreshSuggestion` here. Re-reading is always safe: when this device
    /// already had its own standard, `JudgmentArchive.restore` never touched
    /// the key, so the value on disk is simply the value already in memory.
    private func reloadStrictnessIfChanged() {
        let stored = UserDefaults.standard.double(forKey: Self.strictnessDefaultsKey)
        if stored > 0 { strictness = stored }
    }

    /// The preview shows exactly what a sync would put in the album, in the
    /// album's actual (diversity) order.
    func refreshPreview(container: ModelContainer) async {
        // Every count a drag sweeps through re-keys the task that calls this;
        // none of them is the count the user is choosing, and each would cost
        // a pass over the whole pool (FR-8.2). Letting go re-keys it once more,
        // with the number that matters.
        guard !isAdjustingSize else { return }
        do {
            let result = try await featureStore(container).albumCandidates(limit: count)
            preview = result.candidates
            // The ceiling of FR-6.3's scale, and the last thing the size
            // control was waiting for. A count that overshot a small library
            // needs no correction here: `count` is clamped as it is read, so
            // learning the real ceiling narrows it on the spot.
            totalAccepted = result.acceptedCount
            refreshSizeScale()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Nothing on screen is cleared here, at the start. Every one of these
    /// three — the tally, the error, the album-missing notice — is swapped for
    /// its replacement below, once the replacement exists.
    ///
    /// The card used to blank all three the moment Sync was pressed, so a
    /// second sync collapsed a banner's worth of height out of the card and
    /// put it back a few seconds later, taking the notices and the whole
    /// preview grid with it both times. FR-8.7 calls that out by name: room
    /// once granted is kept, and redoing something moves nothing at all. The
    /// cost is that the previous tally stands for the length of the run, which
    /// is exactly what the requirement asks for — it is the last true thing
    /// the app knows, and the spinner beside the button says a newer one is
    /// coming.
    func sync(container: ModelContainer) {
        isSyncing = true
        let target = count

        Task {
            do {
                // A declined sync (FR-1.9) changes nothing on screen: the last
                // true tally, error and notice all stand, because nothing the
                // app knows has changed.
                if let result = try await WallpaperAlbumSync.sync(
                    container: container,
                    count: target,
                    confirm: { [weak self] change in
                        guard let self else { return false }
                        return await self.confirm(change)
                    }
                ) {
                    outcome = result
                    errorMessage = nil
                    albumMissing = false
                }
            } catch WallpaperAlbumSync.SyncError.albumNotVisible {
                // FR-6.11: not an error to report, a state to wait in.
                albumMissing = true
                errorMessage = nil
                // The tally would otherwise sit there claiming a healthy album
                // this device cannot even see.
                outcome = nil
            } catch {
                errorMessage = error.localizedDescription
                albumMissing = false
                outcome = nil
            }
            // A completed sync rebuilds membership outright, so any earlier
            // interrupted sync is moot — and a failed one may have left a
            // fresh record. Either way this is now the truth.
            hasInterruptedSync = WallpaperAlbumSync.hasInterruptedSync
            isSyncing = false
        }
    }

    /// FR-6.11's escape hatch for the first device, where the album has never
    /// existed anywhere. Deliberately user-driven — see
    /// `WallpaperAlbumSync.createAlbum`.
    func createAlbum() {
        Task {
            do {
                guard try await WallpaperAlbumSync.createAlbum(
                    confirm: { [weak self] change in
                        guard let self else { return false }
                        return await self.confirm(change)
                    }
                ) else { return }
                albumMissing = false
                // Cleared on success rather than on the click, so a failed
                // attempt repeated does not blank the message and re-print it
                // (FR-8.7).
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func featureStore(_ container: ModelContainer) -> FeatureStore {
        if let store { return store }
        let created = FeatureStore(modelContainer: container)
        store = created
        return created
    }
}

/// FR-6.3's proportional scale, in the one form a SwiftUI slider can actually
/// run on.
///
/// A slider is linear between its bounds, so "the scale is proportional — a
/// nudge changes the count by a fraction of it, not a fixed amount" cannot come
/// from the slider itself; it has to come from what the slider is bound to.
/// That is the logarithm of the count, which makes equal travel mean equal
/// *ratio*: the drag that takes 20 to 40 takes 1,000 to 2,000. It is the only
/// scale on which one control reaches from a handful of photos to a library of
/// thousands and stays usable at both ends — a linear track would spend its
/// last nine tenths on counts nobody picks and crush every choice worth making
/// into the first few millimetres.
///
/// A plain value type rebuilt on demand rather than state: it is entirely a
/// function of the pool's size, and there is nothing about it to keep.
struct AlbumSizeScale {
    /// FR-6.3's "a handful of photos".
    let smallest: Int
    /// FR-6.3's "every candidate the library holds".
    let largest: Int

    /// The slider's bounds, in log space.
    ///
    /// Widened by a full ratio step when a library too small to offer any
    /// choice collapses the two ends together: a slider handed an empty range
    /// divides by zero placing its thumb. Nothing is reachable in the room
    /// that invents — the control is disabled for exactly that case — but the
    /// arithmetic still has to be finite.
    var bounds: ClosedRange<Double> {
        let low = log(Double(max(1, smallest)))
        return low...max(log(Double(max(1, largest))), low + 1)
    }

    func position(of count: Int) -> Double { log(Double(max(1, count))) }

    func count(at position: Double) -> Int { Int(exp(position).rounded()) }

    /// Pulls a position that has come close to a mark onto it exactly —
    /// FR-6.3's "one deliberate exception", and now the only thing anywhere
    /// that stops a freely moving thumb.
    ///
    /// FR-6.4 makes moving the thumb onto the suggestion's mark the whole act
    /// of adopting it, which on a track where the thumb can stop anywhere a
    /// hand cannot actually do: it lands on 1,487 next to a suggestion of
    /// 1,510 and the app dutifully remembers a standard of 0.985, forever
    /// almost-following a number the user meant to follow.
    ///
    /// `reach` is how far the catch extends, in the scale's own units. The
    /// caller works it out from a *distance on screen* rather than a share of
    /// the track, because what has to come within reach is a fingertip or a
    /// pointer, and neither grows when the window does — the same mistake, in
    /// the same units, that FR-8.11 was written about.
    func detented(_ position: Double, toward mark: Int?, reach: Double) -> Double {
        guard let mark, reach > 0 else { return position }
        // The ends are never caught. A suggestion can land within reach of one
        // — the calibrated size has no upper bound, so "every photo clears the
        // bar" puts it on the pool size itself — and a catch there would drag
        // the thumb back off the end of the scale, leaving the largest album
        // impossible to choose by dragging. FR-6.3 allows the suggestion one
        // exception to "every count is reachable by dragging"; it does not
        // allow that exception to eat a second count, least of all a named end
        // of the range. The slider hands over the exact bound at its extremes,
        // so nothing else is given up by letting them through.
        guard position > bounds.lowerBound, position < bounds.upperBound else { return position }
        let target = self.position(of: mark)
        guard abs(position - target) < reach else { return position }
        return target
    }

    /// FR-6.3's "few labeled marks at round counts", as counts, strictly
    /// between the ends — the ends carry marks of their own.
    ///
    /// The 1-2-5 ladder is dropped for plain decades once it would put more
    /// than a few marks on the track; see `Thresholds.albumSizeMarkLimit`.
    var marks: [Int] {
        let ladder = roundCounts(mantissas: Thresholds.albumSizeMarkMantissas)
        guard ladder.count > Thresholds.albumSizeMarkLimit else { return ladder }
        return roundCounts(mantissas: [1])
    }

    private func roundCounts(mantissas: [Int]) -> [Int] {
        var counts: [Int] = []
        var decade = 1
        while decade <= largest {
            for mantissa in mantissas {
                let count = mantissa * decade
                if count > smallest && count < largest { counts.append(count) }
            }
            decade *= 10
        }
        return counts.sorted()
    }
}

/// One mark: where it sits on the slider's scale, and what it says.
///
/// A type of its own because the two platforms need the same list for
/// different things — macOS hands it to the system as tick labels, iPhone and
/// iPad draw both the dots and the labels themselves (see
/// `ExportView.markScale`) — and the two must never be allowed to drift into
/// disagreeing about where the marks are.
struct AlbumSizeMark: Identifiable {
    let position: Double
    /// nil once the label has yielded to a neighbour (FR-8.11). The mark stays
    /// — it is a place the thumb can stop — but says nothing.
    var label: String?
    /// Whether the mark's label may be the one dropped. The suggestion's may
    /// not: FR-6.4 exists to put it on the scale, and an unlabeled dot is not
    /// a suggestion. The ends yield to it and to nothing else.
    let rank: Rank

    enum Rank: Int, Comparable {
        case suggestion = 0
        case end = 1
        case round = 2

        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    var id: Double { position }
}

extension AlbumSizeScale {
    /// FR-6.3's marks and FR-6.4's, every one of them, labels intact.
    ///
    /// Nothing is dropped here, because nothing can be: whether two labels
    /// collide depends on how wide they are drawn and how long the track is,
    /// neither of which is known until the view is laid out. `ExportView`
    /// culls them — see its `resolvedMarks`.
    func markCandidates(suggestion: Int?) -> [AlbumSizeMark] {
        // An end of the scale is labeled with its count — or as the
        // suggestion, when the suggestion has landed exactly on it. FR-6.4
        // asks for the suggestion to be marked, not for a second mark in the
        // same place.
        //
        // The smallest end has a third possibility: an estimate below the
        // album's working minimum is real and reported truthfully elsewhere
        // (the "Suggested: N" caption), but the album — and so the slider —
        // never shrinks past this end, so FR-6.4 asks the mark here to say
        // "the minimum, not… the suggestion": it is standing in for a
        // suggestion the track can't reach, not coinciding with one.
        func end(_ count: Int) -> AlbumSizeMark {
            if count == suggestion {
                return AlbumSizeMark(position: position(of: count), label: "Suggested", rank: .suggestion)
            }
            if count == smallest, let suggestion, suggestion < smallest {
                return AlbumSizeMark(position: position(of: count), label: "Minimum", rank: .suggestion)
            }
            return AlbumSizeMark(position: position(of: count), label: count.formatted(), rank: .end)
        }

        // The ends, and the suggestion with them: these are the marks that must
        // be *on* the track whatever happens to their labels. The ends because
        // a slider that snaps its thumb to ticks can otherwise not reach its
        // own extremes, and the suggestion because FR-6.4's "adopting it is
        // moving the thumb onto the mark" is only true if there is a mark to
        // move onto.
        var marks = [end(smallest), end(largest)]
        if let suggestion, suggestion > smallest, suggestion < largest {
            marks.append(
                AlbumSizeMark(
                    position: position(of: suggestion),
                    label: "Suggested",
                    rank: .suggestion
                )
            )
        }

        for count in self.marks {
            marks.append(
                AlbumSizeMark(
                    position: position(of: count),
                    label: count.formatted(),
                    rank: .round
                )
            )
        }

        // One mark per place on the track, the highest-ranking one.
        //
        // The suggestion can still land exactly on a round mark or an end —
        // FR-6.4 no longer rounds it to one on purpose, but an unrounded
        // estimate is free to coincide with one anyway (10, 100, or the pool's
        // own size, say). Left alone, the twins would sit at the identical
        // position and print "Suggested" across the round count's own label —
        // the plainest possible breach of FR-8.11. It would also hand
        // `ForEach` two marks with one id, since `AlbumSizeMark` is identified
        // by its position.
        //
        // The same twinning happens at the ends when a library is smaller than
        // the smallest album and both ends land on the same count.
        return Dictionary(grouping: marks, by: \.position)
            .values
            .compactMap { $0.min(by: { $0.rank < $1.rank }) }
            .sorted { $0.position < $1.position }
    }
}

/// The marks on the album-size slider: FR-6.3's round counts, the two ends,
/// and FR-6.4's suggestion among them.
///
/// **What a tick does differs by platform, and the SDK says so nowhere.**
/// Measured both ways on 2026-08-08 (SDK 27; the tick API is macOS/iOS 26.0),
/// because neither the headers nor the documentation mention the behaviour at
/// all and there is no API to select it — AppKit's `allowsTickMarkValuesOnly`
/// has no SwiftUI counterpart:
///
/// - **iOS 27 (simulator): the thumb snaps to the nearest tick.** A slider
///   ticked at 0.1, 0.6 and 0.9, dragged from 0.5 to squarely 0.30 — far from
///   every tick — came to rest at exactly 0.10000.
/// - **macOS 27: the thumb moves freely** and the ticks are marks on the
///   track. This very slider, dragged to a point between the 100 mark and the
///   suggestion at 1,510, settled on 181.
///
/// So on the Mac the marks are what FR-6.3 asks them to be and no more — a
/// scale to read the unusual track against — while on iPhone and iPad they are
/// also where the count can stop, moving it in ratio steps (×2, ×2.5, ×2 up
/// the ladder), which is FR-6.3's "a nudge changes the count by a fraction of
/// it, not a fixed amount" met about as literally as it can be. Everything
/// between the marks is still reached by typing it, which is the number field
/// FR-6.3 asks for in the same breath.
///
/// Two things follow, and both are load-bearing. Thickening the ladder to make
/// the iOS drag feel continuous is not an option: every tick is drawn, and
/// forty on one track is a picket fence (seen, in the same test). And the
/// Mac's free movement is why `AlbumSizeScale.detented` exists — without it,
/// FR-6.4's "adopting it is moving the thumb onto the mark" would be
/// unachievable on the one platform where the thumb can stop anywhere.
///
/// **iPhone and iPad draw no tick labels at all** — measured 2026-08-08 on
/// the iOS 27 simulator, after the iPad reported the scale unreadable. Three
/// sliders with identically labeled ticks, differing only in their own label
/// (`EmptyView`, a `Text`, a `Text` plus `.labelsHidden()`), all drew bare
/// dots and not one word. It is the platform, not the label-less
/// initializer, and there is no modifier that turns it on.
///
/// That is why `ExportView.markScale` exists: FR-6.3 does not exempt the
/// iPad, and the scale has to be readable there too.
///
/// **This type is the Mac's alone.** iPhone and iPad are handed no ticks at
/// all now — ticks were what confined the thumb to the marks, which FR-6.3
/// forbids — so there the dots as well as the words are drawn by `markScale`,
/// and nothing here is called. The Mac keeps them because AppKit both draws
/// and labels its ticks, and never confined the thumb to them.
///
/// A hand-rolled conformance rather than `SliderTickContentForEach` because
/// the protocol asks only for a collection of ticks, and the marks are
/// computed elsewhere as one list — several sources, sorted together, with
/// crowded ones dropped — which is a list to hand over, not a collection to
/// iterate.
#if os(macOS)
struct AlbumSizeTicks: SliderTickContent {
    /// Stated rather than inferred: the protocol leaves `Value` free, and
    /// nothing about `[SliderTick<Double>]` pins it down for the compiler.
    typealias Value = Double

    let marks: [AlbumSizeMark]

    var body: [SliderTick<Double>] {
        // A mark whose label yielded to a neighbour (FR-8.11) keeps its tick
        // and loses its words.
        marks.map { mark in
            if let label = mark.label {
                SliderTick(label, mark.position)
            } else {
                SliderTick(mark.position)
            }
        }
    }
}
#endif

/// Export tab: syncs the top-ranked candidates into the Photos wallpaper
/// album, previewing exactly which photos will be in it.
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ExportModel()
    /// What the number field is showing. See `sizeControls` for why the field
    /// edits a draft rather than the count.
    @State private var draftCount = Thresholds.defaultWallpaperCount
    /// Whether that draft has been typed into since it last matched the count.
    /// See `commitCount`.
    @State private var draftIsEdited = false
    @FocusState private var countFieldFocused: Bool
    /// Grows with the user's text size: the field has to hold the widest count
    /// the library can produce.
    @ScaledMetric private var countFieldWidth: CGFloat = 64
    /// How wide the slider actually is, which is the only basis on which
    /// FR-8.11 can be honoured — see `resolvedMarks`. Read without a
    /// `GeometryReader` so that measuring the row does not also lay it out.
    @State private var sliderWidth: CGFloat = 0
    /// Room for the hand-drawn mark labels on iPhone and iPad. Reserved at a
    /// fixed height so the row cannot change size as the labels change (FR-8.7),
    /// and scaled so it still fits them at larger text sizes.
    @ScaledMetric private var markLabelHeight: CGFloat = 14
    #if !os(macOS)
    /// Whether the settings sheet is up. iPhone and iPad only — the Mac has
    /// the standard Settings window.
    @State private var isShowingSettings = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                controls
                    .frame(maxWidth: 560)

                if model.totalAccepted == nil {
                    ProgressView("Loading candidates…")
                        .padding(.top, 40)
                        .shownWhileWaiting()
                } else if !model.preview.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(model.preview) { candidate in
                            ThumbnailCell(candidate: candidate)
                        }
                    }
                }

                #if !os(macOS)
                // The way into the app's settings on a platform with no
                // Settings window and no menu bar to put one behind (FR-8.4:
                // every command reachable by touch, none of them only behind a
                // gesture). It sits with the identity footer at the foot of
                // the app's one bounded screen, for the same reason About does
                // — see About.swift. On the Mac this is the standard Settings
                // window instead (⌘,), so there is nothing here.
                Button("Settings…") { isShowingSettings = true }
                    .padding(.top, 24)

                // FR-8.8's iPhone and iPad half: the app's identity at the
                // foot of its last screen, where macOS has an About box
                // instead. Static, so it never shifts anything above it
                // (FR-8.7). See About.swift for why here.
                AboutFooter()
                #endif
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        #if !os(macOS)
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSettings = false }
                        }
                    }
            }
        }
        #endif
        // FR-1.9: every change the app is about to make in Photos, named
        // before it happens, with the way to stop being asked about that kind
        // of change in the alert itself.
        //
        // It lives on this view because this view is where every write
        // originates — the Sync button, the Create Album button, the restore,
        // and the menu command that drives the same model. The sync is
        // suspended while it stands, so answering it *is* the sync continuing
        // or not happening at all.
        .alert(
            model.pendingChange?.change.title ?? "",
            isPresented: Binding(
                get: { model.pendingChange != nil },
                // Only ever set by the buttons below, each of which answers
                // first; this is the dismissal the system may perform itself.
                set: { if !$0 && model.pendingChange != nil { model.answerPendingChange(approve: false) } }
            ),
            presenting: model.pendingChange
        ) { pending in
            Button("Cancel", role: .cancel) {
                model.answerPendingChange(approve: false)
            }
            Button(pending.change.confirmTitle) {
                model.answerPendingChange(approve: true)
            }
            Button("Always Allow") {
                model.answerPendingChange(approve: true, remember: true)
            }
        } message: { pending in
            Text(pending.change.message)
        }
        // A pending question with nobody to read it would leave the sync that
        // asked it suspended for good. Nothing can dismiss this view while the
        // alert is up on either platform, but the sync outliving the view is
        // the one failure that could not be recovered from, so it is closed
        // off rather than reasoned away.
        .onDisappear { model.answerPendingChange(approve: false) }
        // FR-8.3: lets the menu bar's "Sync Album" trigger the same sync
        // this view's button does.
        .focusedSceneValue(\.exportCommandTarget, ExportCommandTarget(model: model, modelContext: modelContext))
        // FR-1.8 / FR-1.3: pick up an access upgrade made in Settings while the
        // app was in the background, on the tab that acts on it. `.task` covers
        // the tab appearing; `.onChange` covers returning to a tab already on
        // screen, which is exactly the Settings round-trip.
        .task { model.refreshAccess() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { model.refreshAccess() }
        }
        .task(id: RankingClock.shared.version) {
            await model.refreshSuggestion(container: modelContext.container)
        }
        // The count moves without the user touching it — a fresh suggestion
        // carries it (FR-6.12), and learning the pool's real size narrows it —
        // so the number field follows it. Never while there's an unsaved edit
        // in progress: that half-typed number outranks ours. Gating on focus
        // alone was wrong — the field can hold focus (tabbed or clicked into,
        // or via dragging the slider without ever touching the field) with
        // nothing typed, which isn't an edit and shouldn't freeze the field
        // out of every update, including the slider's own.
        .onChange(of: model.count, initial: true) { _, newCount in
            if !draftIsEdited { draftCount = newCount }
        }
        .task(id: "\(model.count)|\(model.isAdjustingSize)|\(RankingClock.shared.version)") {
            await model.refreshPreview(container: modelContext.container)
        }
    }

    /// FR-6.7, the hand-off, and the one place the two platforms genuinely
    /// part ways. On the Mac the album is the last step the app can take for
    /// the user, so this points at the System Settings pane that turns it into
    /// a rotating desktop. On iPhone and iPad there is no such pane and no
    /// supported way for any app to set wallpaper (see REQUIREMENTS.md's
    /// Parked list), so the honest thing — and what FR-6.7 asks for — is to
    /// say that the Mac is where wallpaper happens, rather than leave the user
    /// hunting for a button that cannot exist.
    private var handOffText: String {
        // "the", not "a": there is exactly one such album, and the article has
        // to read correctly whatever `wallpaperAlbumName` is — "a “Firnlight”"
        // is wrong today (seen on the iPad), and "an" would be wrong the moment
        // the name started with a consonant sound.
        let album = "Keeps the “\(Thresholds.wallpaperAlbumName)” album in Photos in sync with your top-ranked wallpapers, previewed below."
        #if os(macOS)
        return album + " In System Settings → Wallpaper, choose “Add Photo Album” and pick it for automatic rotation."
        #else
        return album + " Firnlight doesn't set wallpaper here — iPhone and iPad don't let apps do that. The album syncs to your Mac through iCloud Photos, and you point System Settings → Wallpaper at it there."
        #endif
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wallpaper Album")
                    .font(.headline)

                Text(handOffText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sizeControls

                HStack(spacing: 12) {
                    Button("Sync Album") {
                        model.sync(container: modelContext.container)
                    }
                    .buttonStyle(.borderedProminent)
                    // Same gate as the menu command: also disabled while the
                    // pool is still loading or empty, not just mid-sync.
                    .disabled(!model.canSync)

                    // The wait goes beside the button, never into its title.
                    // "Syncing…" is narrower than "Sync Album", so the button
                    // shrank the instant it was clicked and grew back when the
                    // sync landed — FR-8.7's "never the control whose use
                    // produced it", about the one control most likely to still
                    // be under the pointer. Faded in place rather than
                    // inserted, and delayed, so an album already in sync
                    // reports nothing at all.
                    ProgressView()
                        .controlSize(.small)
                        .shownWhileWaiting(model.isSyncing)

                    if let outcome = model.outcome {
                        if outcome.orderVerified {
                            Label(
                                "Album has \(outcome.total) photos (+\(outcome.added), −\(outcome.removed) this sync)",
                                systemImage: "checkmark.circle"
                            )
                            .foregroundStyle(.green)
                            .font(.callout.monospacedDigit())
                            .help("The sync finished — the Photos album now matches the preview below.")
                        } else {
                            // FR-6.6: the sync itself succeeded, but the
                            // post-sync read-back found Photos didn't end up
                            // in the requested diversity order — surface that
                            // honestly instead of showing the same green
                            // success label the mismatch would otherwise hide
                            // behind (see WallpaperAlbumSync.sync's order
                            // verification).
                            Label(
                                "Album synced, but Photos reported a different order — try syncing again.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .help("The album has \(outcome.total) photos, but their order in Photos doesn't match the preview below. Syncing again usually fixes it.")
                        }
                    }
                }

                // The three standing notices sit *under* the Sync button, not
                // between it and the count (FR-8.7). Each of them appears and
                // disappears while this tab is on screen — `albumMissing` as
                // the direct result of pressing Sync, the other two on a
                // return from Settings — and above the button that meant the
                // button dropped half a card's height away from the pointer
                // that had just clicked it. Below, they push only the preview
                // grid, which nothing is aiming at.
                if model.albumMissing {
                    albumMissingNotice
                }

                if model.hasInterruptedSync {
                    interruptedSyncNotice
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }

    /// FR-6.3's album-size control: one slider over the whole candidate pool,
    /// with the exact count beside it.
    ///
    /// Every part of it is present and the same size from the first frame,
    /// disabled until the two numbers it is made of have arrived (FR-6.5,
    /// FR-8.7). The card this sits in used to shove the Sync button down a
    /// line when the suggestion landed; nothing here appears or disappears, so
    /// there is nothing left to shove. The marks the slider draws do change
    /// when the suggestion moves — but a mark is a drawing on a track, not a
    /// control, and the track keeps its size.
    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Top")
                // FR-6.3 keeps the exact count typeable. The field edits a
                // draft rather than the count itself: the count is clamped to
                // the pool as it is read, and clamping every keystroke would
                // rewrite "1" to the floor while the user was still on their
                // way to "120". `commitCount` folds the draft in on submit or
                // on losing focus, which is where the clamp belongs.
                TextField("Count", value: $draftCount, format: .number)
                    .labelsHidden()
                    .frame(width: countFieldWidth)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .focused($countFieldFocused)
                    // FR-6.5: no count at all until there is a true one to
                    // show — a greyed-out 50 is still a default count, and
                    // reads as the app's answer rather than as its silence.
                    // Drawn out of the field it already has rather than
                    // swapped for another view, so the row keeps its shape
                    // (FR-8.7).
                    .foregroundStyle(model.isReady ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                    .overlay {
                        if !model.isReady {
                            Text(verbatim: "—").foregroundStyle(.secondary)
                        }
                    }
                    // Distinct from the slider's, which carries the same
                    // name: two siblings answering to one label leaves Voice
                    // Control's "tap Album size" ambiguous and the rotor
                    // listing two identical entries (FR-8.1).
                    .accessibilityLabel("Exact album size")
                    .onChange(of: draftCount) { _, _ in
                        if countFieldFocused { draftIsEdited = true }
                    }
                    .onSubmit { commitCount() }
                    .onChange(of: countFieldFocused) { _, focused in
                        if !focused { commitCount() }
                    }
                // The unit, not a control: it says what the number counts.
                // What used to sit here was a stepper, from the days when
                // FR-6.3 asked for a number field and a stepper. FR-6.3 now
                // asks for one slider plus the typeable count, and FR-8.10
                // forbids a second control doing the same job in the same
                // place — the slider reaches the whole range from a handful of
                // photos to the entire library, the stepper only ever moved by
                // one, so the stepper is the one that goes.
                Text("photos")
                    .foregroundStyle(.secondary)
            }

            sizeSlider

            // What the mark means, and what it is. The slider shows where the
            // app would draw the line, but only a number says where that is
            // without moving the thumb to find out — and the thumb is the
            // setting, so finding out would change it. Hover text could carry
            // neither (FR-4.13). The sentence keeps its line as the number
            // grows a digit, so the card stays still (FR-8.7).
            Text("Suggested: \(suggestionText) — where quality drops off in your ranking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!model.isReady)
    }

    private var suggestionText: String {
        model.markedSuggestion?.formatted() ?? "—"
    }

    /// FR-6.3's slider, and FR-6.4's mark on it.
    ///
    /// The value it runs on is the count in log space (`AlbumSizeScale`), so
    /// the thumb moves proportionally rather than by a fixed number of photos.
    /// VoiceOver is told the count instead: the raw value is a logarithm, and
    /// announcing "4.8" to someone choosing an album size would be worse than
    /// silence.
    ///
    /// The marks are left to keep themselves current. A widely repeated claim
    /// has it that SwiftUI builds a slider's ticks once and never re-evaluates
    /// them, which would need the whole slider given a new identity whenever
    /// the pool size or the suggestion changed — and that cure is worse than
    /// the disease, since a view rebuilt under a thumb cancels the drag and
    /// drops keyboard and VoiceOver focus. Measured on 2026-08-08 (SDK 27),
    /// the claim is false: a `SliderTickContent`'s `body` is re-evaluated when
    /// the state it reads changes, like any other view's.
    ///
    /// `onEditingChanged` is what tells the model a drag is in flight; see
    /// `ExportModel.isAdjustingSize` for the two things that suppresses.
    private var sizeSlider: some View {
        let scale = model.sizeScale
        let marks = resolvedMarks(on: scale)
        return VStack(spacing: 2) {
            Group {
                #if os(macOS)
                // The Mac keeps the system's ticks: there they are drawn *and*
                // labeled by AppKit, and they never confined the thumb.
                Slider(
                    value: Bindable(model).sizePosition,
                    in: scale.bounds,
                    label: { EmptyView() },
                    ticks: { AlbumSizeTicks(marks: marks) },
                    onEditingChanged: { model.isAdjustingSize = $0 }
                )
                #else
                // iPhone and iPad get a plain slider, deliberately. Handing
                // this one `ticks:` is what confined its thumb to the marks —
                // measured, and now forbidden by FR-6.3, which wants every
                // count reachable by dragging on every platform. Since the
                // system draws no tick *labels* there either, nothing is lost
                // by dropping the ticks: `markScale` below draws both the dots
                // and the words, and `AlbumSizeScale.detented` supplies the
                // one catch FR-6.3 still asks for.
                Slider(
                    value: Bindable(model).sizePosition,
                    in: scale.bounds,
                    label: { EmptyView() },
                    onEditingChanged: { model.isAdjustingSize = $0 }
                )
                #endif
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                sliderWidth = $0
                model.trackWidth = $0
            }
            .accessibilityLabel("Album size")
            .accessibilityValue("\(model.count.formatted()) photos")
            // A slider's default assistive step is a tenth of its range, which
            // on this scale is close to a doubling of the count per press —
            // about eleven counts reachable in the whole library. Left over
            // from the ticks, whose stops used to be what an increment landed
            // on; now that they are gone the step is stated here instead, one
            // tenth *of the count* rather than of the track, which is the same
            // proportional nudge FR-6.3 asks the thumb for.
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment
                    ? Thresholds.albumSizeAssistiveStep
                    : 1 / Thresholds.albumSizeAssistiveStep
                model.count = Int((Double(model.count) * step).rounded())
                draftCount = model.count
            }
            .accessibilityHint("Adjusts in proportion. Type an exact count in the field above.")

            #if !os(macOS)
            markScale(marks, on: scale)
            #endif
        }
        // A library smaller than the smallest album offers no choice to make.
        .disabled(model.largestSize <= model.smallestSize)
    }

    /// FR-8.11, for this slider: the marks, with every label that would have
    /// been drawn over another taken away.
    ///
    /// The rule this replaces kept labels apart by a fraction of the track,
    /// which cannot be made to work and did not: a label's width is a fixed
    /// number of points, while the track stretches with the window and the
    /// words grow with the reader's text size, so any fraction is too small
    /// somewhere. It failed on the iPad at a suggestion of 740, where
    /// "Suggested" printed across the 1,000 mark.
    ///
    /// What decides it now is the thing that actually collides: the drawn
    /// width of each label, at the reader's text size, against the real width
    /// of the track. Marks are placed in order of rank — the suggestion first,
    /// because FR-6.4 exists to show it; then the ends; then the round counts
    /// left to right — and a label is kept only if its box, plus a gap, clears
    /// every label already kept. What yields is only ever the *label*: the mark
    /// stays on the track, so nothing the thumb could stop at disappears.
    ///
    /// Because the test is made in points, it holds for every state the app
    /// can reach rather than the ones that happened to be tried: a narrow
    /// iPhone, accessibility text sizes, a translation where "Suggested" is
    /// half again as long, and any suggestion value, including one landing a
    /// hair from a round count or from the end of the scale.
    private func resolvedMarks(on scale: AlbumSizeScale) -> [AlbumSizeMark] {
        let candidates = scale.markCandidates(suggestion: model.markedSuggestion)

        // Before the first layout there is no track to measure against, so
        // every label is taken away rather than left on. Keeping them meant
        // the first frame of every visit to this tab drew the whole set
        // unculled and piled on top of each other — a reachable state, and so
        // one FR-8.11 covers. Silence for one frame is the honest version of
        // "not known yet", and the labels fade in a frame later.
        guard sliderWidth > 0 else {
            return candidates.map { var mark = $0; mark.label = nil; return mark }
        }

        let span = scale.bounds.upperBound - scale.bounds.lowerBound
        let inset = Thresholds.sliderTrackInset
        let usable = max(sliderWidth - inset * 2, 1)

        func box(for mark: AlbumSizeMark, label: String) -> ClosedRange<CGFloat> {
            let fraction = span > 0 ? (mark.position - scale.bounds.lowerBound) / span : 0
            let centre = inset + usable * CGFloat(fraction)
            let half = labelWidth(label) / 2 + Thresholds.albumSizeLabelGap / 2
            #if os(macOS)
            // AppKit keeps an end tick's label inside the track rather than
            // centring it on the tick — measured off the Mac's own card, where
            // "7,834" sits about 16pt left of the tick it belongs to. Modelling
            // it as centred would understate how far it reaches inward and let
            // a round mark just inside the end collide with it.
            if mark.position <= scale.bounds.lowerBound {
                return 0...(2 * half)
            }
            if mark.position >= scale.bounds.upperBound {
                return (sliderWidth - 2 * half)...sliderWidth
            }
            #endif
            return (centre - half)...(centre + half)
        }

        var kept: [ClosedRange<CGFloat>] = []
        var labelled: Set<Int> = []

        for index in candidates.indices.sorted(by: {
            (candidates[$0].rank, candidates[$0].position) < (candidates[$1].rank, candidates[$1].position)
        }) {
            guard let label = candidates[index].label else { continue }
            let extent = box(for: candidates[index], label: label)
            if kept.contains(where: { $0.overlaps(extent) }) { continue }
            kept.append(extent)
            labelled.insert(index)
        }

        return candidates.indices.map { index in
            var mark = candidates[index]
            if !labelled.contains(index) { mark.label = nil }
            return mark
        }
    }

    /// How wide a mark's label is drawn, at the reader's current text size.
    ///
    /// Measured through the platform's own font metrics rather than estimated
    /// from the character count, because the answer has to be right for text
    /// the app has never seen — a translated "Suggested", a grouping separator
    /// that is a space in one locale and a dot in another.
    ///
    /// macOS is measured a size up from what this app draws, because there the
    /// labels are drawn by the *system* as part of the slider's ticks, in a
    /// font this code never picks and cannot ask for. Over-measuring costs at
    /// worst one round mark that would have fitted; under-measuring costs the
    /// overlap FR-8.11 forbids.
    /// Memoised, because this runs inside `body` and `body` runs on every
    /// frame of a drag — the slider writes the count, the count is read back
    /// for the accessibility value — while the answer cannot change during
    /// one: a drag freezes the scale and the suggestion, and the track does
    /// not resize under the thumb. Laying out half a dozen strings through
    /// CoreText at 120 Hz to be told the same numbers each time is the shape
    /// of work FR-8.2 exists to keep away from the interface. The font is part
    /// of the key, so the cache follows the reader changing their text size.
    private static var labelWidths: [LabelWidthKey: CGFloat] = [:]

    private struct LabelWidthKey: Hashable {
        let label: String
        let fontSize: CGFloat
    }

    private func labelWidth(_ label: String) -> CGFloat {
        #if os(macOS)
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        #else
        let font = UIFont.preferredFont(forTextStyle: .caption2)
        #endif
        let key = LabelWidthKey(label: label, fontSize: font.pointSize)
        if let cached = Self.labelWidths[key] { return cached }
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        Self.labelWidths[key] = width
        return width
    }

    #if !os(macOS)
    /// FR-6.3's scale on iPhone and iPad: the marks and their labels, both
    /// drawn here because the platform now draws neither.
    ///
    /// It never drew the labels (see `AlbumSizeTicks`), and it no longer draws
    /// the dots either — the slider is given no ticks at all, since ticks were
    /// what confined the thumb to them, which FR-6.3 forbids. So the dots move
    /// here to keep the scale visible, one per mark, including the marks whose
    /// label yielded to a neighbour (FR-8.11): a mark with no room for its
    /// word is still a place on the scale worth showing.
    ///
    /// Placed against the system's own track geometry: a slider insets its
    /// track by half a thumb at each end (`Thresholds.sliderTrackInset`), so a
    /// mark at fraction *f* sits at `inset + f × (width − 2 × inset)`. The end
    /// labels are centred on their marks like the rest, which lets them
    /// overhang slightly; the card's padding is wider than the overhang, so
    /// nothing is clipped and nothing shifts.
    ///
    /// Hidden from VoiceOver, which reads the slider itself rather than the
    /// scale beside it: the value and range are already announced, and the
    /// caption below names the suggested count in words. Exposed, these would
    /// be four bare numbers sitting between the slider and the next control.
    private func markScale(_ marks: [AlbumSizeMark], on scale: AlbumSizeScale) -> some View {
        let span = scale.bounds.upperBound - scale.bounds.lowerBound
        return GeometryReader { proxy in
            let usable = max(proxy.size.width - Thresholds.sliderTrackInset * 2, 1)
            ForEach(marks) { mark in
                let fraction = span > 0 ? (mark.position - scale.bounds.lowerBound) / span : 0
                let x = Thresholds.sliderTrackInset + usable * fraction
                Circle()
                    .fill(.tertiary)
                    .frame(width: Thresholds.albumSizeMarkDotSize, height: Thresholds.albumSizeMarkDotSize)
                    .position(x: x, y: Thresholds.albumSizeMarkDotSize / 2)
                if let label = mark.label {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(
                            x: x,
                            y: Thresholds.albumSizeMarkDotSize
                                + (proxy.size.height - Thresholds.albumSizeMarkDotSize) / 2
                        )
                }
            }
        }
        .frame(height: markLabelHeight + Thresholds.albumSizeMarkDotSize)
        .accessibilityHidden(true)
    }
    #endif

    /// Folds a typed count into the choice — but only if one was actually
    /// typed.
    ///
    /// Committing on every loss of focus meant that clicking into the field
    /// and back out, changing nothing, wrote a ratio (FR-6.12) and so ended
    /// "follow the suggestion" for good, which FR-6.4 gives only the slider
    /// the power to do. Worse, the number written back could be stale — the
    /// field deliberately stops following the count while it has focus, so a
    /// suggestion arriving during the visit would be undone on the way out —
    /// or clamped, which would launder a momentarily small pool into a
    /// permanent standard, the very thing `clampedToPool` keeps off the
    /// stored ratio.
    private func commitCount() {
        defer { draftIsEdited = false }
        guard draftIsEdited else {
            draftCount = model.count
            return
        }
        model.count = draftCount
        draftCount = model.count
    }

    /// FR-6.8: a previous sync died between removing the album's contents and
    /// putting the new ones back, so the album may be sitting empty or half
    /// rebuilt. Offered rather than done on launch: these devices share one
    /// album, and restoring unattended could silently undo a sync the user
    /// deliberately made somewhere else (FR-6.10). Syncing again fixes it too —
    /// a sync rebuilds membership outright — so this is the option for when
    /// what was in the album matters more than what would be.
    private var interruptedSyncNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "The last sync didn't finish, so the album may be incomplete.",
                systemImage: "arrow.uturn.backward.circle"
            )
            .foregroundStyle(.orange)
            Text("Restore puts the album back exactly as it was before that sync. Syncing again instead rebuilds it from your current ranking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Same shape as the Sync button above, and for the same reason:
            // the busy state is a spinner in reserved space beside the button
            // rather than a shorter title inside it, so the control the user
            // just clicked keeps its size (FR-8.7).
            HStack(spacing: 12) {
                Button("Restore Previous Album") {
                    model.restoreInterruptedSync()
                }
                .disabled(model.isRestoring)

                ProgressView()
                    .controlSize(.small)
                    .shownWhileWaiting(model.isRestoring)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// FR-6.11: this device can't see the album. Say so and wait — the usual
    /// cause is a second device whose iCloud Photos sync hasn't brought the
    /// album down yet, and creating one here would leave the user with two.
    /// The button covers the only other cause: a first device, where the album
    /// has never existed anywhere.
    private var albumMissingNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Waiting for the “\(Thresholds.wallpaperAlbumName)” album to appear on this device.",
                systemImage: "icloud.and.arrow.down"
            )
            .foregroundStyle(.orange)
            Text("If you've already used Firnlight on another device, the album will arrive once iCloud Photos finishes syncing — syncing now would create a second one. If this is your first device, create it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Disabled while a sync or restore is already asking or writing —
            // otherwise this was the one trigger with no guard at all, able to
            // ask a second consent question while, say, a restore's was still
            // up (`confirm` now queues rather than strands either caller, but
            // running two album writes at once is still worth keeping off).
            Button("Create Album") { model.createAlbum() }
                .disabled(model.isSyncing || model.isRestoring)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
