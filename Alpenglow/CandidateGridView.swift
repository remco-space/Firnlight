import SwiftUI
import SwiftData
import Photos
import Observation
import AppKit

/// Loads the ranked, deduplicated candidate list off the main actor.
@MainActor
@Observable
final class GridModel {
    private(set) var result: FeatureStore.RankedResult?
    private(set) var ignored: [Candidate] = []
    private(set) var isLoading = false

    private var store: FeatureStore?
    private var pendingReload = false

    func load(container: ModelContainer) async {
        // Coalesce overlapping requests: while a load runs, remember that one
        // more is wanted and run it once at the end instead of queuing each.
        if isLoading {
            pendingReload = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        let store = store(container)
        repeat {
            pendingReload = false
            result = try? await store.rankedCandidates()
        } while pendingReload
    }

    /// Loads the ignored photos for the "Show Ignored" review filter.
    func loadIgnored(container: ModelContainer) async {
        ignored = (try? await store(container).ignoredCandidates()) ?? []
    }

    private func store(_ container: ModelContainer) -> FeatureStore {
        let store = self.store ?? FeatureStore(modelContainer: container)
        self.store = store
        return store
    }
}

/// Ranked grid of top wallpaper candidates with lazy thumbnails.
struct CandidateGridView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model = GridModel()
    @State private var showingIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if showingIgnored {
                ignoredGrid
            } else {
                candidateGrid
            }
        }
        .task(id: "\(showingIgnored)|\(RankingClock.shared.version)") {
            // Reloads on appearance and after every duel choice re-trains the
            // ranker; also on toggling the ignored filter.
            if showingIgnored {
                await model.loadIgnored(container: modelContext.container)
            } else {
                await model.load(container: modelContext.container)
            }
        }
    }

    @ViewBuilder
    private var candidateGrid: some View {
        if let result = model.result, !result.candidates.isEmpty {
            grid(result.candidates, ignoredMode: false)
        } else if model.result != nil {
            ContentUnavailableView(
                "No Candidates Yet",
                systemImage: "photo.stack",
                description: Text("Run the scan and analysis above — accepted photos appear here, best first.")
            )
        }
    }

    @ViewBuilder
    private var ignoredGrid: some View {
        if model.ignored.isEmpty {
            ContentUnavailableView(
                "No Ignored Photos",
                systemImage: "eye.slash",
                description: Text("Photos you ignore appear here so you can restore them.")
            )
        } else {
            grid(model.ignored, ignoredMode: true)
        }
    }

    private func grid(_ candidates: [Candidate], ignoredMode: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
            spacing: 12
        ) {
            ForEach(candidates) { candidate in
                ThumbnailCell(candidate: candidate, isIgnoredMode: ignoredMode)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Top Candidates")
                .font(.headline)

            if let result = model.result, !showingIgnored {
                Text("\(result.candidates.count) of \(result.acceptedCount) accepted · \(result.suppressedCount) near-duplicates hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Show Ignored", isOn: $showingIgnored)
                .toggleStyle(.switch)
                .controlSize(.small)

            if model.isLoading && !showingIgnored {
                ProgressView()
                    .controlSize(.small)
            } else if !showingIgnored {
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
    /// When shown in the Library "Show Ignored" filter: the cell badges an
    /// ignored marker instead of a score and offers "Un-ignore".
    var isIgnoredMode = false
    @Environment(\.modelContext) private var modelContext
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
            // clipShape clips drawing but NOT hit-testing: a panorama's
            // scaledToFill overflow would otherwise be clickable far beyond
            // the visible tile. contentShape bounds interaction to the tile.
            .contentShape(RoundedRectangle(cornerRadius: 8))
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
        .overlay(alignment: .bottomTrailing) { badge }
        .contextMenu { menu }
        .task {
            if thumbnail == nil {
                thumbnail = await ThumbnailLoader.load(candidate.localIdentifier)
            }
        }
        // One accessibility element per cell: an unlabeled score/badge overlay
        // is invisible to VoiceOver otherwise.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var badge: some View {
        if isIgnoredMode {
            Image(systemName: "eye.slash.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(.ultraThinMaterial, in: Circle())
                .padding(5)
        } else {
            // Learned preference (sigmoid of the raw score) once the ranker is
            // live, aesthetics prior before.
            Text(
                candidate.displayScore,
                format: .number.precision(.fractionLength(2))
            )
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(5)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open in Photos") {
            CandidateActions.openInPhotos(candidate.localIdentifier)
        }
        Divider()
        if isIgnoredMode {
            Button("Un-ignore") {
                CandidateActions.unignore(candidate.localIdentifier, in: modelContext)
            }
        } else {
            Button("Not Wallpaper Material") {
                CandidateActions.markNotWallpaperMaterial(candidate.localIdentifier, in: modelContext)
            }
            Button("Ignore This Photo", role: .destructive) {
                CandidateActions.ignore(candidate.localIdentifier, in: modelContext)
            }
        }
    }

    private var accessibilityLabel: String {
        if isIgnoredMode {
            return candidate.isFavorite ? "Ignored photo, favorite" : "Ignored photo"
        }
        let score = candidate.displayScore.formatted(.number.precision(.fractionLength(2)))
        return candidate.isFavorite ? "Score \(score), favorite" : "Score \(score)"
    }
}

/// Context-menu actions shared by every image shown in the app.
@MainActor
enum CandidateActions {
    /// Best-effort deep link; the scheme is undocumented but widely used.
    /// Falls back to just opening Photos if navigation isn't supported.
    static func openInPhotos(_ localIdentifier: String) {
        let uuid = localIdentifier.components(separatedBy: "/").first ?? localIdentifier
        guard let url = URL(string: "photos://asset?uuid=\(uuid)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// "Not Wallpaper Material": the human judges this a bad wallpaper on face
    /// value. This does NOT exclude — it records the same absolute bad-quality
    /// verdict the duel's "Both Are Bad" writes, so the photo stays in the
    /// ranking and duels but drags the album-size calibration's quality bar.
    /// (It may still rank high enough to appear, though that's unlikely.)
    static func markNotWallpaperMaterial(_ localIdentifier: String, in modelContext: ModelContext) {
        modelContext.insert(VerdictRecord(localIdentifier: localIdentifier, isGood: false, timestamp: Date()))
        try? modelContext.save()
        RankingClock.shared.bump() // calibration + dependent views reload
    }

    /// "Ignore This Photo": fully drop it from the grid, duels, calibration,
    /// and (on next sync) the wallpaper album. Reviewable/reversible via the
    /// Library tab's "Show Ignored" filter. Sets the ignored flag (stored as
    /// `isExcluded` — see PhotoRecord).
    static func ignore(_ localIdentifier: String, in modelContext: ModelContext) {
        setIgnored(localIdentifier, true, in: modelContext)
    }

    /// Reverses `ignore`, returning the photo to the normal pipeline.
    static func unignore(_ localIdentifier: String, in modelContext: ModelContext) {
        setIgnored(localIdentifier, false, in: modelContext)
    }

    private static func setIgnored(_ localIdentifier: String, _ ignored: Bool, in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier }
        )
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        record.isExcluded = ignored
        try? modelContext.save()
        RankingClock.shared.bump() // grid + export preview + suggestion reload
    }
}

/// Fetches display bitmaps from PhotoKit at a requested size.
nonisolated enum ThumbnailLoader {
    static func load(_ localIdentifier: String, pixelSize: Int = Thresholds.gridThumbnailPixelSize) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        let side = CGFloat(pixelSize)
        return await PhotoImageLoading.image(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            allowNetwork: true
        )
    }
}
