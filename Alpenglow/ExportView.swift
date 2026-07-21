import SwiftUI
import SwiftData

/// Export tab: syncs the top-ranked candidates into the Photos wallpaper
/// album, previewing exactly which photos will be in it.
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var count = Thresholds.defaultWallpaperCount
    @State private var suggestion: Int?
    @State private var hasAdoptedSuggestion = false
    @State private var preview: [Candidate] = []
    /// nil until the first `albumCandidates` load completes; the count/stepper
    /// bounds have no sane fallback before then, so the controls stay disabled.
    @State private var totalAccepted: Int?
    @State private var isSyncing = false
    @State private var outcome: WallpaperAlbumSync.Outcome?
    @State private var errorMessage: String?
    @FocusState private var countFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                controls
                    .frame(maxWidth: 560)

                if totalAccepted == nil {
                    ProgressView("Loading candidates…")
                        .padding(.top, 40)
                } else if !preview.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(preview) { candidate in
                            ThumbnailCell(candidate: candidate)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .task(id: RankingClock.shared.version) {
            // Recompute when duels re-rank; only auto-adopt the very first time
            // so the stepper never fights a manual choice.
            let store = FeatureStore(modelContainer: modelContext.container)
            do {
                let suggested = try await store.suggestedAlbumSize()
                suggestion = suggested
                if !hasAdoptedSuggestion {
                    count = suggested
                    hasAdoptedSuggestion = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .task(id: "\(count)|\(RankingClock.shared.version)") {
            // The preview shows exactly what a sync would put in the album,
            // in the album's actual (diversity) order.
            let store = FeatureStore(modelContainer: modelContext.container)
            do {
                let result = try await store.albumCandidates(limit: count)
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
    }

    private var stepperUpperBound: Int {
        max(1, totalAccepted ?? count)
    }

    private func commitCount() {
        count = min(max(count, 1), stepperUpperBound)
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
                    TextField("Count", value: $count, format: .number)
                        .labelsHidden()
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .focused($countFieldFocused)
                        .onSubmit { commitCount() }
                        .onChange(of: countFieldFocused) { _, focused in
                            if !focused { commitCount() }
                        }
                    Stepper("photos", value: $count, in: 1...stepperUpperBound, step: 10)
                }
                .disabled(totalAccepted == nil)

                if let suggestion {
                    HStack(spacing: 8) {
                        Text("Suggested: \(suggestion) — where quality drops off in your ranking")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if suggestion != count {
                            Button("Use") {
                                count = suggestion
                                commitCount()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(isSyncing ? "Syncing…" : "Sync Album") {
                        sync()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSyncing)

                    if let outcome {
                        Label(
                            "Album has \(outcome.total) photos (+\(outcome.added), −\(outcome.removed) this sync)",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.green)
                        .font(.callout.monospacedDigit())
                        .help("The sync finished — the Photos album now matches the preview below.")
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }

    private func sync() {
        isSyncing = true
        errorMessage = nil
        let container = modelContext.container
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
}
