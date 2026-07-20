import SwiftUI
import SwiftData
import Photos
import Observation

/// Loads the ranked, deduplicated candidate list off the main actor.
@MainActor
@Observable
final class GridModel {
    private(set) var result: FeatureStore.RankedResult?
    private(set) var isLoading = false

    private var store: FeatureStore?

    func load(container: ModelContainer) async {
        isLoading = true
        defer { isLoading = false }

        let store = self.store ?? FeatureStore(modelContainer: container)
        self.store = store
        // FeatureStore is an actor, so overlapping loads serialize; the last
        // caller's assignment wins, which matches the freshest ranking.
        result = try? await store.rankedCandidates()
    }
}

/// Ranked grid of top wallpaper candidates with lazy thumbnails.
struct CandidateGridView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model = GridModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let result = model.result, !result.candidates.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(result.candidates) { candidate in
                        ThumbnailCell(candidate: candidate)
                    }
                }
            } else if model.result != nil {
                ContentUnavailableView(
                    "No Candidates Yet",
                    systemImage: "photo.stack",
                    description: Text("Run the scan and analysis above — accepted photos appear here, best first.")
                )
            }
        }
        .task(id: RankingClock.shared.version) {
            // Reloads on appearance and after every duel choice re-trains the ranker.
            await model.load(container: modelContext.container)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Top Candidates")
                .font(.headline)

            if let result = model.result {
                Text("\(result.candidates.count) of \(result.acceptedCount) accepted · \(result.suppressedCount) near-duplicates hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Refresh") {
                    Task { await model.load(container: modelContext.container) }
                }
            }
        }
    }
}

/// One grid cell: lazily loaded thumbnail with a score badge.
/// Shared by the Library grid and the Export album preview.
struct ThumbnailCell: View {
    let candidate: Candidate
    @State private var thumbnail: CGImage?

    var body: some View {
        // The image lives in an overlay so a filled (e.g. panoramic) thumbnail
        // can't propose an oversized layout and spill into neighboring cells.
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if candidate.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Learned preference once the ranker is live, aesthetics prior before.
            Text(
                candidate.preferenceScore != 0 ? candidate.preferenceScore : candidate.aestheticsScore,
                format: .number.precision(.fractionLength(2))
            )
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(5)
        }
        .task {
            if thumbnail == nil {
                thumbnail = await ThumbnailLoader.load(candidate.localIdentifier)
            }
        }
    }
}

/// Fetches display bitmaps from PhotoKit at a requested size.
nonisolated enum ThumbnailLoader {
    static func load(_ localIdentifier: String, pixelSize: Int = Thresholds.gridThumbnailPixelSize) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let side = CGFloat(pixelSize)

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }
}
