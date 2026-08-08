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
    var count = Thresholds.defaultWallpaperCount
    private(set) var suggestion: Int?
    private var hasAdoptedSuggestion = false
    private(set) var preview: [Candidate] = []
    /// nil until the first `albumCandidates` load completes; the count/stepper
    /// bounds have no sane fallback before then, so the controls stay disabled.
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

    var stepperUpperBound: Int { max(1, totalAccepted ?? count) }

    func commitCount() {
        count = min(max(count, 1), stepperUpperBound)
    }

    func adoptSuggestion() {
        guard let suggestion else { return }
        count = suggestion
        commitCount()
    }

    /// Recompute when duels re-rank; only auto-adopt the very first time so
    /// the stepper never fights a manual choice.
    func refreshSuggestion(container: ModelContainer) async {
        do {
            let suggested = try await featureStore(container).suggestedAlbumSize()
            suggestion = suggested
            if !hasAdoptedSuggestion {
                count = suggested
                hasAdoptedSuggestion = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The preview shows exactly what a sync would put in the album, in the
    /// album's actual (diversity) order.
    func refreshPreview(container: ModelContainer) async {
        do {
            let result = try await featureStore(container).albumCandidates(limit: count)
            preview = result.candidates
            totalAccepted = result.acceptedCount
            // The default count and an adopted suggestion can both exceed
            // a small library; clamp once the real ceiling is known.
            if count > result.acceptedCount {
                count = max(1, result.acceptedCount)
            }
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

/// Export tab: syncs the top-ranked candidates into the Photos wallpaper
/// album, previewing exactly which photos will be in it.
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ExportModel()
    @FocusState private var countFieldFocused: Bool

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
        .task(id: "\(model.count)|\(RankingClock.shared.version)") {
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

                // Typed entry for an exact count, plus stepper arrows for quick
                // nudges. No hardcoded ceiling: if every photo is awesome, the
                // album can be the whole candidate pool.
                HStack(spacing: 8) {
                    Text("Top")
                    TextField("Count", value: Bindable(model).count, format: .number)
                        .labelsHidden()
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .focused($countFieldFocused)
                        .onSubmit { model.commitCount() }
                        .onChange(of: countFieldFocused) { _, focused in
                            if !focused { model.commitCount() }
                        }
                    Stepper("photos", value: Bindable(model).count, in: 1...model.stepperUpperBound, step: 10)
                }
                .disabled(model.totalAccepted == nil)

                suggestionRow

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

    /// FR-4.7's suggested album size, in a row that is always there.
    ///
    /// The suggestion is computed asynchronously and recomputed on every
    /// re-rank, so it arrives after this tab has drawn and can change or
    /// vanish later. Inserting the row on arrival shoved the Sync button — and
    /// everything under it — down a line just as the user reached for it, so
    /// the row is laid out at full height from the start and its contents fade
    /// in (FR-8.7). "Use" is reserved the same way rather than being dropped
    /// when the count already matches: it disappears at the instant it is
    /// clicked, which is the worst possible moment to resize the row it is in.
    ///
    /// Height was only half of it. The placeholder stands in `model.count` for
    /// the number the suggestion will carry, and the two rarely have the same
    /// number of digits — 8 becoming 120 widens the text, and with the button
    /// packed straight after it, "Use" slid sideways the moment the suggestion
    /// landed. The `Spacer` pins the button to the card's trailing edge, which
    /// is fixed, so the text can now grow into the gap between them instead of
    /// pushing the control along (FR-8.7).
    private var suggestionRow: some View {
        HStack(spacing: 8) {
            Text("Suggested: \(model.suggestion ?? model.count) — where quality drops off in your ranking")
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(model.suggestion == nil ? 0 : 1)
                .accessibilityHidden(model.suggestion == nil)
            Spacer(minLength: 8)
            Button("Use") { model.adoptSuggestion() }
                .controlSize(.small)
                .opacity(canAdoptSuggestion ? 1 : 0)
                .disabled(!canAdoptSuggestion)
                .accessibilityHidden(!canAdoptSuggestion)
        }
    }

    private var canAdoptSuggestion: Bool {
        guard let suggestion = model.suggestion else { return false }
        return suggestion != model.count
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
