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
    private static let duelPairFirstKey = "duelPairFirst"
    private static let duelPairSecondKey = "duelPairSecond"

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
                setPair(await ranker.nextPair())
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
                // record() persists the choice durably and updates the ranker's
                // in-memory scores immediately; nextPair() below draws from those
                // fresh scores. The store-side preferenceScore cache is flushed on
                // a debounce inside the ranker, which bumps RankingClock once it
                // persists — so we neither write the whole library nor fan out a
                // grid/export reload here on every single choice (FR-8.2).
                try await ranker.record(winnerID: winner.localIdentifier, loserID: loser.localIdentifier)
                choiceCount = await ranker.choiceCount
            } catch {
                lastError = error.localizedDescription
            }
            setPair(await ranker.nextPair())
            isRecording = false
        }
    }

    func skip() {
        guard !isRecording, let ranker else { return }
        Task { setPair(await ranker.nextPair()) }
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
            setPair(await ranker.nextPair())
            isRecording = false
        }
    }

    /// Looks up the persisted pair from last launch, if any, and hands back a
    /// live `DuelPair` only if both photos are still candidates.
    private func restoredPair(ranker: PreferenceRanker) async -> PreferenceRanker.DuelPair? {
        let defaults = UserDefaults.standard
        guard let first = defaults.string(forKey: Self.duelPairFirstKey),
              let second = defaults.string(forKey: Self.duelPairSecondKey) else {
            return nil
        }
        return await ranker.pair(first: first, second: second)
    }

    /// Sets `pair` and keeps the persisted identifiers in lockstep: written
    /// whenever a new pair is served (covers choice/skip/verdict/ignore, all
    /// of which route through here), cleared when the pair becomes nil (no
    /// more candidates to compare) so a stale pair is never resumed.
    private func setPair(_ newPair: PreferenceRanker.DuelPair?) {
        pair = newPair
        let defaults = UserDefaults.standard
        if let newPair {
            defaults.set(newPair.first.localIdentifier, forKey: Self.duelPairFirstKey)
            defaults.set(newPair.second.localIdentifier, forKey: Self.duelPairSecondKey)
        } else {
            defaults.removeObject(forKey: Self.duelPairFirstKey)
            defaults.removeObject(forKey: Self.duelPairSecondKey)
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
                            duelModel: model
                        )
                        DuelCard(
                            candidate: pair.second,
                            positionLabel: "Right photo",
                            aspectRatio: Self.screenAspectRatio,
                            action: { model.choose(winner: pair.second, loser: pair.first) },
                            duelModel: model
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
            // Prepares on first appearance; on later bumps (a scan/exclusion, or
            // the ranker's own debounced cache flush landing) reloads the
            // candidate snapshot so new/excluded photos show up. Coalesced to
            // flush boundaries now, not fired per choice.
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
    /// Advances to a fresh pair after this photo is ignored or judged not
    /// wallpaper material (either way the current pair is spent), and is
    /// published inside `FocusedPhoto` so the menu-bar photo actions can do
    /// the same (FR-4.7/FR-4.8) — see AppCommands.swift.
    let duelModel: DuelModel

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
                duelModel.skip()
            }
            Button("Ignore This Photo", role: .destructive) {
                ignore()
            }
        }
        .onHover { isHovering = $0 }
        // Duel cards are already focusable (they're Buttons); publish the
        // focused candidate the same way ThumbnailCell does, so the Photo
        // menu (FR-4.6) reaches duel cards too. Never in "ignored" mode —
        // an ignored photo can't reach a duel pair.
        .focusedValue(\.focusedPhoto, FocusedPhoto(
            localIdentifier: candidate.localIdentifier,
            isIgnored: false,
            modelContext: modelContext,
            duelModel: duelModel
        ))
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
        duelModel.skip()
    }
}
