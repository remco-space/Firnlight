import SwiftUI
import SwiftData
import Observation
import AppKit

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
    private(set) var lastError: String?

    private var ranker: PreferenceRanker?

    func start(container: ModelContainer) async {
        guard ranker == nil else { return }
        isPreparing = true
        defer { isPreparing = false }

        let ranker = PreferenceRanker(modelContainer: container)
        self.ranker = ranker
        do {
            try await ranker.prepare()
            choiceCount = await ranker.choiceCount
            pair = await ranker.nextPair()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func choose(winner: Candidate, loser: Candidate) {
        guard !isRecording, let ranker else { return }
        isRecording = true

        Task {
            do {
                try await ranker.record(winnerID: winner.localIdentifier, loserID: loser.localIdentifier)
                choiceCount = await ranker.choiceCount
                RankingClock.shared.bump()
            } catch {
                lastError = error.localizedDescription
            }
            pair = await ranker.nextPair()
            isRecording = false
        }
    }

    func skip() {
        guard !isRecording, let ranker else { return }
        Task { pair = await ranker.nextPair() }
    }

    /// "Both great" / "both bad": an absolute quality verdict on both photos,
    /// used to calibrate the suggested album size — then advance.
    func judgeBoth(isGood: Bool) {
        guard !isRecording, let ranker, let pair else { return }
        isRecording = true
        Task {
            do {
                try await ranker.recordVerdicts(
                    [pair.first.localIdentifier, pair.second.localIdentifier],
                    isGood: isGood
                )
                RankingClock.shared.bump() // suggestion recalibrates
            } catch {
                lastError = error.localizedDescription
            }
            self.pair = await ranker.nextPair()
            isRecording = false
        }
    }
}

/// Pairwise A/B picker: click the photo that makes the better wallpaper.
struct DuelView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model = DuelModel()

    var body: some View {
        Group {
            if let pair = model.pair {
                VStack(spacing: 16) {
                    Text("Which makes the better wallpaper?")
                        .font(.title3.bold())

                    HStack(spacing: 16) {
                        DuelCard(
                            candidate: pair.first,
                            aspectRatio: Self.screenAspectRatio,
                            action: { model.choose(winner: pair.first, loser: pair.second) },
                            onExclude: { model.skip() }
                        )
                        DuelCard(
                            candidate: pair.second,
                            aspectRatio: Self.screenAspectRatio,
                            action: { model.choose(winner: pair.second, loser: pair.first) },
                            onExclude: { model.skip() }
                        )
                    }

                    HStack(spacing: 12) {
                        // No winner for the pairwise ranker, but an absolute
                        // verdict that calibrates the album-size suggestion.
                        Button("Both Are Great") { model.judgeBoth(isGood: true) }
                            .disabled(model.isRecording)
                        Button("Both Are Bad") { model.judgeBoth(isGood: false) }
                            .disabled(model.isRecording)
                        Button("Skip") { model.skip() }
                            .disabled(model.isRecording)
                        Text("\(model.choiceCount) choices made")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if model.isRecording {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .padding(24)
            } else if model.isPreparing {
                ProgressView("Preparing ranker…")
            } else if let error = model.lastError {
                ContentUnavailableView("Ranker Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView(
                    "Nothing to Compare",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Scan and analyze your library first — duels need at least two candidates.")
                )
            }
        }
        .task {
            await model.start(container: modelContext.container)
        }
    }

    /// Aspect ratio of the main display — duel images are cropped to it so
    /// choices are made on what the wallpaper would actually show.
    private static var screenAspectRatio: CGFloat {
        guard let screen = NSScreen.main, screen.frame.height > 0 else { return 16.0 / 10.0 }
        return screen.frame.width / screen.frame.height
    }
}

/// One side of the duel: the photo center-cropped to the display's shape, clickable.
private struct DuelCard: View {
    let candidate: Candidate
    let aspectRatio: CGFloat
    let action: () -> Void
    let onExclude: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var image: CGImage?
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
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
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Photos") {
                CandidateActions.openInPhotos(candidate.localIdentifier)
            }
            Divider()
            Button("Not Wallpaper Material", role: .destructive) {
                CandidateActions.exclude(candidate.localIdentifier, in: modelContext)
                onExclude()
            }
        }
        .onHover { isHovering = $0 }
        .task(id: candidate.localIdentifier) {
            image = nil
            image = await ThumbnailLoader.load(candidate.localIdentifier, pixelSize: Thresholds.duelImagePixelSize)
        }
    }
}
