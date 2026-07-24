import SwiftUI
import SwiftData

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
    /// One reused model actor (and its ModelContext) for both reload tasks.
    /// Spinning up a fresh FeatureStore per keystroke/re-rank churned contexts
    /// against the store; `.task(id:)` already cancels a superseded run, so a
    /// stable store coalesces Export's two loads the way GridModel coalesces the
    /// grid's — the second half of taming the per-choice fan-out (FR-8.2).
    private var store: FeatureStore?

    /// Whether "Sync Album" (button or menu command) has anything to do
    /// right now. Also stands in for "not authorized" in the menu command's
    /// disabled state: with no Photos access the candidate pool is always
    /// empty, so `totalAccepted` never rises above 0 and this reads false
    /// without needing its own authorization plumbing.
    var canSync: Bool { !isSyncing && (totalAccepted ?? 0) > 0 }

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

    func sync(container: ModelContainer) {
        isSyncing = true
        errorMessage = nil
        let target = count

        Task {
            do {
                outcome = try await WallpaperAlbumSync.sync(container: container, count: target)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSyncing = false
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
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        // FR-8.3: lets the menu bar's "Sync Album" trigger the same sync
        // this view's button does.
        .focusedSceneValue(\.exportCommandTarget, ExportCommandTarget(model: model, modelContext: modelContext))
        .task(id: RankingClock.shared.version) {
            await model.refreshSuggestion(container: modelContext.container)
        }
        .task(id: "\(model.count)|\(RankingClock.shared.version)") {
            await model.refreshPreview(container: modelContext.container)
        }
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wallpaper Album")
                    .font(.headline)

                Text("Keeps a “\(Thresholds.wallpaperAlbumName)” album in Photos in sync with your top-ranked wallpapers, previewed below. In System Settings → Wallpaper, choose “Add Photo Album” and pick it for automatic rotation.")
                    .foregroundStyle(.secondary)

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

                if let suggestion = model.suggestion {
                    HStack(spacing: 8) {
                        Text("Suggested: \(suggestion) — where quality drops off in your ranking")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if suggestion != model.count {
                            Button("Use") { model.adoptSuggestion() }
                                .controlSize(.small)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(model.isSyncing ? "Syncing…" : "Sync Album") {
                        model.sync(container: modelContext.container)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSyncing)

                    if let outcome = model.outcome {
                        Label(
                            "Album has \(outcome.total) photos (+\(outcome.added), −\(outcome.removed) this sync)",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.green)
                        .font(.callout.monospacedDigit())
                        .help("The sync finished — the Photos album now matches the preview below.")
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }
}
