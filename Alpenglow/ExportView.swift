import SwiftUI
import SwiftData
import Photos

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

    /// FR-1.8 *(iPhone and iPad)*: under limited access PhotoKit cannot create
    /// or fetch user albums at all, so there is no album to maintain and no
    /// way to find out there isn't — `performChanges` reports success and the
    /// following fetch returns nothing. Blocking the sync up front is what
    /// keeps the app from appearing to work.
    ///
    /// Read straight from PhotoKit rather than through
    /// `PhotoLibraryAuthorization`: that observable is `ContentView`-owned
    /// `@State` and isn't in the environment, and `authorizationStatus(for:)`
    /// is a cached synchronous read, so threading it down here would be
    /// plumbing for its own sake. `.limited` is `API_AVAILABLE(ios(14))` and
    /// has no macOS counterpart, hence the platform split rather than a
    /// status comparison that would always be false on the Mac.
    ///
    /// Stored and refreshed rather than computed on demand: `@Observable`
    /// tracks stored properties, so a computed one reading PhotoKit would
    /// never invalidate the view. Upgrading to full access is a trip to
    /// Settings and back, and `isAuthorized` reads true both before and after
    /// (limited counts as authorized), so nothing else in the app re-renders
    /// this tab on that transition — without the refresh the notice would sit
    /// there claiming the album is impossible after the user had just fixed it
    /// (FR-1.3).
    private(set) var isLimitedAccess = false

    func refreshAccess() {
        #if os(iOS)
        isLimitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        #endif
        hasInterruptedSync = WallpaperAlbumSync.hasInterruptedSync
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
            await WallpaperAlbumSync.restoreInterruptedSync()
            hasInterruptedSync = WallpaperAlbumSync.hasInterruptedSync
            isRestoring = false
        }
    }

    /// Whether "Sync Album" (button or menu command) has anything to do
    /// right now. Also stands in for "not authorized" in the menu command's
    /// disabled state: with no Photos access the candidate pool is always
    /// empty, so `totalAccepted` never rises above 0 and this reads false
    /// without needing its own authorization plumbing. Limited access is the
    /// exception that proxy misses — the selected photos still scan, so the
    /// pool is non-empty while the album remains impossible (FR-1.8).
    var canSync: Bool { !isSyncing && !isLimitedAccess && (totalAccepted ?? 0) > 0 }

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
    private static let strictnessDefaultsKey = "WallpaperAlbum.sizeStrictness"

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
    /// so moves whenever the suggestion does. Writing to it — from the slider,
    /// the stepper or the number field — records a new ratio; that is the only
    /// way one is ever written.
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
    var sizePosition: Double {
        get { sizeScale.position(of: count) }
        set {
            count = sizeScale.count(at: sizeScale.detented(newValue, toward: markedSuggestion))
        }
    }

    /// FR-6.4: recompute whenever the ranking moves. Nothing here adopts
    /// anything — with the choice held as a ratio (see `strictness`), a fresh
    /// suggestion carries the count with it automatically for a user who has
    /// never moved the slider, and equally automatically leaves the standard
    /// of one who has.
    func refreshSuggestion(container: ModelContainer) async {
        do {
            suggestion = try await featureStore(container).suggestedAlbumSize()
            refreshSizeScale()
        } catch {
            errorMessage = error.localizedDescription
        }
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
                outcome = try await WallpaperAlbumSync.sync(container: container, count: target)
                errorMessage = nil
                albumMissing = false
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
                try await WallpaperAlbumSync.createAlbum()
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

    /// Pulls a position that has come close to a mark onto it exactly.
    ///
    /// FR-6.4 makes moving the thumb onto the suggestion's mark the whole act
    /// of adopting it, which on a track where the thumb can stop anywhere —
    /// macOS, see `AlbumSizeTicks` — a hand cannot actually do: it lands on
    /// 1,487 next to a suggestion of 1,510 and the app dutifully remembers a
    /// standard of 0.985, forever almost-following a number the user meant to
    /// follow. A detent makes the mark reachable, which is what iOS's own
    /// snapping already does there, so this changes nothing on that side.
    func detented(_ position: Double, toward mark: Int?) -> Double {
        guard let mark else { return position }
        let target = self.position(of: mark)
        let span = bounds.upperBound - bounds.lowerBound
        guard abs(position - target) < Thresholds.albumSizeDetent * span else { return position }
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
/// A hand-rolled conformance rather than `SliderTickContentForEach` because
/// the protocol asks only for a collection of ticks, and the marks here are
/// computed as one list — several sources, sorted together, with crowded ones
/// dropped — which is a list to hand over, not a collection to iterate.
struct AlbumSizeTicks: SliderTickContent {
    /// Stated rather than inferred: the protocol leaves `Value` free, and
    /// nothing about `[SliderTick<Double>]` pins it down for the compiler.
    typealias Value = Double

    let scale: AlbumSizeScale
    let suggestion: Int?
    /// `Thresholds.albumSizeMarkSpacing`, scaled to the reader's text size by
    /// the view that supplies it.
    let spacing: Double

    private struct Mark {
        let position: Double
        let label: String
    }

    var body: [SliderTick<Double>] {
        // The ends first, and the suggestion with them: these three are the
        // marks that must be on the track. The ends because a slider that
        // snaps its thumb to ticks can otherwise not reach its own extremes,
        // and the suggestion because FR-6.4's "adopting it is moving the thumb
        // onto the mark" is only true if there is a mark to move onto.
        var marks = [end(scale.smallest), end(scale.largest)]
        if let suggestion, suggestion > scale.smallest, suggestion < scale.largest {
            marks.append(Mark(position: scale.position(of: suggestion), label: "Suggested"))
        }

        // Round marks give way when they would collide with one of those,
        // rather than the other way round: an unreadable pair of overlapping
        // labels loses the app both marks, and of the two the round one is the
        // one the user can do without.
        let span = scale.bounds.upperBound - scale.bounds.lowerBound
        for count in scale.marks {
            let position = scale.position(of: count)
            let crowded = marks.contains {
                abs($0.position - position) < spacing * span
            }
            if !crowded {
                marks.append(Mark(position: position, label: count.formatted()))
            }
        }

        return marks
            .sorted { $0.position < $1.position }
            .map { SliderTick($0.label, $0.position) }
    }

    /// An end of the scale, labeled with its count — or as the suggestion,
    /// when the suggestion has landed exactly on it. FR-6.4 asks for the
    /// suggestion to be marked, not for a second mark in the same place.
    private func end(_ count: Int) -> Mark {
        Mark(
            position: scale.position(of: count),
            label: count == suggestion ? "Suggested" : count.formatted()
        )
    }
}

/// Export tab: syncs the top-ranked candidates into the Photos wallpaper
/// album, previewing exactly which photos will be in it.
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ExportModel()
    /// What the number field is showing. See `sizeControls` for why the field
    /// edits a draft rather than the count.
    @State private var draftCount = Thresholds.defaultWallpaperCount
    /// Whether that draft has been typed into since it last matched the count.
    /// See `commitCount`.
    @State private var draftIsEdited = false
    @FocusState private var countFieldFocused: Bool
    /// Both of these grow with the user's text size. The field has to hold the
    /// widest count the library can produce, and the slider's marks have to
    /// clear labels that grow with it — a gap fixed in fractions of the track
    /// stops being enough the moment the words get bigger, and the marks
    /// overlap instead of standing aside (see `Thresholds.albumSizeMarkSpacing`).
    @ScaledMetric private var countFieldWidth: CGFloat = 64
    @ScaledMetric private var markSpacing: Double = Thresholds.albumSizeMarkSpacing

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
        // so the number field follows it. Never while it has focus: that is
        // someone mid-edit, and their half-typed number outranks ours.
        .onChange(of: model.count, initial: true) { _, newCount in
            if !countFieldFocused { draftCount = newCount }
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
        // to read correctly whatever `wallpaperAlbumName` is — "a “Alpenglow”"
        // is wrong today (seen on the iPad), and "an" would be wrong the moment
        // the name started with a consonant sound.
        let album = "Keeps the “\(Thresholds.wallpaperAlbumName)” album in Photos in sync with your top-ranked wallpapers, previewed below."
        #if os(macOS)
        return album + " In System Settings → Wallpaper, choose “Add Photo Album” and pick it for automatic rotation."
        #else
        return album + " Alpenglow doesn't set wallpaper here — iPhone and iPad don't let apps do that. The album syncs to your Mac through iCloud Photos, and you point System Settings → Wallpaper at it there."
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
                if model.isLimitedAccess {
                    limitedAccessNotice
                }

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
                    .accessibilityLabel("Album size")
                    .onChange(of: draftCount) { _, _ in
                        if countFieldFocused { draftIsEdited = true }
                    }
                    .onSubmit { commitCount() }
                    .onChange(of: countFieldFocused) { _, focused in
                        if !focused { commitCount() }
                    }
                Stepper("photos", value: steppedCount, in: model.smallestSize...model.largestSize)
                    // The chevrons are the whole control; "photos" is a unit,
                    // not a name for what they do (FR-4.13).
                    .accessibilityLabel("Album size")
                    .help("Adjust the album size one photo at a time")
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
        return Slider(
            value: Bindable(model).sizePosition,
            in: scale.bounds,
            label: { EmptyView() },
            ticks: { AlbumSizeTicks(scale: scale, suggestion: model.markedSuggestion, spacing: markSpacing) },
            onEditingChanged: { model.isAdjustingSize = $0 }
        )
        .accessibilityLabel("Album size")
        .accessibilityValue("\(model.count.formatted()) photos")
        // VoiceOver's own increments walk the log scale, which moves the count
        // by a large ratio a press at a time — right for the scale, useless for
        // landing on a particular number, so the way to do that is named here.
        .accessibilityHint("Adjusts in proportion. Type an exact count in the field above.")
        // A library smaller than the smallest album offers no choice to make.
        .disabled(model.largestSize <= model.smallestSize)
    }

    /// The stepper writes through to the draft as well as the count, so the
    /// number beside it is never a stale edit waiting to be committed.
    private var steppedCount: Binding<Int> {
        Binding(
            get: { model.count },
            set: { newCount in
                model.count = newCount
                draftCount = model.count
            }
        )
    }

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

    /// FR-1.8 *(iPhone and iPad)*: with limited access there is no album to
    /// maintain, so say that plainly at the point the user would try to sync,
    /// and offer the only route to full access there is.
    private var limitedAccessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Alpenglow can't maintain the album with limited photo access.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            Text("Photos only lets apps create and update albums with access to your whole library. Allow access to all photos to use the wallpaper album.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = PhotoLibraryAuthorization.settingsURL {
                Button("Allow Access to All Photos…") { openURL(url) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
            Text("If you've already used Alpenglow on another device, the album will arrive once iCloud Photos finishes syncing — syncing now would create a second one. If this is your first device, create it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create Album") { model.createAlbum() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
