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

    /// Set right before a bump this model itself causes: record() has already
    /// rescored and saved, so the clock-driven reload would redo the whole
    /// library's rescore-and-persist for nothing on every single choice.
    private var suppressNextReload = false

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
            pair = await ranker.nextPair()
        } catch {
            lastError = error.localizedDescription
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
                self.pair = await ranker.nextPair()
            }
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
                suppressNextReload = true
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
                suppressNextReload = true // verdicts don't change the pool
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
                            positionLabel: "Left photo",
                            aspectRatio: Self.screenAspectRatio,
                            action: { model.choose(winner: pair.first, loser: pair.second) },
                            onAdvance: { model.skip() }
                        )
                        DuelCard(
                            candidate: pair.second,
                            positionLabel: "Right photo",
                            aspectRatio: Self.screenAspectRatio,
                            action: { model.choose(winner: pair.second, loser: pair.first) },
                            onAdvance: { model.skip() }
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
        .task(id: RankingClock.shared.version) {
            // Prepares on first appearance; on later re-rank/exclusion bumps,
            // reloads the candidate snapshot so new/excluded photos show up.
            await model.reload(container: modelContext.container)
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
    /// VoiceOver label for the pick button, e.g. "Left photo" / "Right photo".
    let positionLabel: String
    let aspectRatio: CGFloat
    let action: () -> Void
    /// Advance to a fresh pair after this photo is ignored or judged not
    /// wallpaper material — either way the current pair is spent.
    let onAdvance: () -> Void

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
                        .help("You marked this photo as a favorite in Photos, which boosts its ranking.")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.isFavorite ? "\(positionLabel), favorite" : positionLabel)
        // Ignore lives in its own button overlaid on (in front of) the pick
        // button, so its taps aren't swallowed as a duel choice.
        .overlay(alignment: .topTrailing) { ignoreButton }
        .contextMenu {
            Button("Open in Photos") {
                CandidateActions.openInPhotos(candidate.localIdentifier)
            }
            Divider()
            Button("Not Wallpaper Material") {
                // Records a bad verdict; the photo stays in the duel pool, but
                // this pair is spent — advance (FR-4.7).
                CandidateActions.markNotWallpaperMaterial(candidate.localIdentifier, in: modelContext)
                onAdvance()
            }
            Button("Ignore This Photo", role: .destructive) {
                ignore()
            }
        }
        .onHover { isHovering = $0 }
        .task(id: candidate.localIdentifier) {
            image = nil
            image = await ThumbnailLoader.load(candidate.localIdentifier, pixelSize: Thresholds.duelImagePixelSize)
        }
    }

    private var ignoreButton: some View {
        Button(action: ignore) {
            Image(systemName: "eye.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Ignore \(positionLabel)")
        .help("Click to ignore this photo — it leaves the grid, duels, and the wallpaper album (reversible via “Show Ignored” in the Library tab).")
    }

    private func ignore() {
        CandidateActions.ignore(candidate.localIdentifier, in: modelContext)
        onAdvance()
    }
}
