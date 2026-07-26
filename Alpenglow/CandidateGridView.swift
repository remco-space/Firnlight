import SwiftUI
import SwiftData
import Photos
import Observation
import CoreGraphics
import os

/// Loads the ranked, deduplicated candidate list off the main actor.
@MainActor
@Observable
final class GridModel {
    private(set) var result: FeatureStore.RankedResult?
    private(set) var ignored: [Candidate] = []
    private(set) var isLoading = false
    /// The Library tab's "Show Ignored" filter (FR-4.9). Lives here rather
    /// than as view-local `@State` so it has one source of truth reachable
    /// both from `CandidateGridView`'s own switch and from the View menu's
    /// "Show Ignored" toggle — the model is published via
    /// `.focusedSceneValue(\.libraryGridModel, self)` below and read back by
    /// `AppCommands` (see AppCommands.swift for the focusedValue plumbing).
    var showingIgnored = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.showingIgnored {
                ignoredGrid
            } else {
                candidateGrid
            }
        }
        .task(id: "\(model.showingIgnored)|\(RankingClock.shared.version)") {
            // Reloads on appearance and after every duel choice re-trains the
            // ranker; also on toggling the ignored filter.
            if model.showingIgnored {
                await model.loadIgnored(container: modelContext.container)
            } else {
                await model.load(container: modelContext.container)
            }
        }
        // FR-8.3: lets the View menu's "Show Ignored" toggle control the
        // same model this view's own switch does.
        .focusedSceneValue(\.libraryGridModel, model)
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
        } else {
            // FR-4.11: the very first load (before `result` is populated at
            // all) showed nothing here — unlike ExportView's "Loading
            // candidates…" state for the same underlying wait. A placeholder
            // keeps every lazily-loading tab consistent instead of only this
            // one going blank.
            ProgressView("Loading candidates…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
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
            // The heading names what is actually below it. With the filter on
            // that is the ignored photos the user came here to review (FR-4.9),
            // and calling them "Top Candidates" would misdescribe the screen —
            // they are precisely the photos held *out* of the ranking.
            Text(model.showingIgnored ? "Ignored Photos" : "Top Candidates")
                .font(.headline)

            if let result = model.result, !model.showingIgnored {
                Text("\(result.candidates.count) of \(result.acceptedCount) accepted · \(result.suppressedCount) near-duplicates hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Show Ignored", isOn: Bindable(model).showingIgnored)
                .toggleStyle(.switch)
                .controlSize(.small)
                // Without this the switch drifts to the far edge of an iPad
                // window: a `Toggle` takes all the width it is offered and
                // pushes its label and its control to opposite ends, which on
                // the Mac's narrower window is invisible but on iPad left the
                // switch ~300pt from the words "Show Ignored" and directly
                // beside "Refresh" — reading as Refresh's control. `fixedSize`
                // holds the toggle to its ideal width so label and switch stay
                // together, which is what FR-4.13 asks of any control and what
                // FR-8.4 needs for this one to be nameable by touch.
                .fixedSize()

            if model.isLoading && !model.showingIgnored {
                ProgressView()
                    .controlSize(.small)
            } else if !model.showingIgnored {
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
    @Environment(\.openURL) private var openURL
    @State private var thumbnail: CGImage?

    var body: some View {
        tile
            // The actions menu sits *outside* `tile`, and so outside its
            // `.accessibilityElement(children: .ignore)`, which would
            // otherwise swallow the only touch path to the photo actions
            // (FR-8.4) and leave VoiceOver unable to reach them.
            .overlay(alignment: .topTrailing) { actionsMenu }
            .contextMenu { menu }
            .task {
                if thumbnail == nil {
                    thumbnail = await ThumbnailLoader.load(candidate.localIdentifier)
                }
            }
            // Tab-focusable with the system focus ring, so keyboard/VoiceOver
            // users can reach every cell without a mouse, and so the Photo menu
            // (FR-4.6/FR-8.3) has something to act on: `.focusedValue` publishes
            // this cell's candidate only while focus is actually inside it — see
            // AppCommands.swift for how AppCommands reads it back. Shared by the
            // Library grid and the Export preview, so both get this for free.
            .focusable()
            .focusedValue(\.focusedPhoto, FocusedPhoto(
                localIdentifier: candidate.localIdentifier,
                isIgnored: isIgnoredMode,
                modelContext: modelContext
            ))
    }

    /// The photo itself, its badges, and nothing interactive — one labelled
    /// accessibility element.
    private var tile: some View {
        // The image lives in an overlay so a filled (e.g. panoramic) thumbnail
        // can't propose an oversized layout and spill into neighboring cells.
        // The tile is the same desktop rectangle the duel judges and the
        // analysis measures, so the grid shows the crop the ranking is about.
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(Thresholds.desktopAspectRatio, contentMode: .fit)
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
            // scaledToFill overflow would otherwise be clickable — or, on
            // iPhone and iPad, tappable — far beyond the visible tile.
            // contentShape bounds interaction to the tile, for clicks and
            // taps alike (FR-4.10), and it is applied here rather than on the
            // finished cell so it can't override the actions menu's own hit
            // region.
            .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if candidate.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
                    .padding(5)
                    .help("You marked this photo as a favorite in Photos, which boosts its ranking.")
            }
        }
        .overlay(alignment: .bottomTrailing) { badge }
        // One accessibility element per cell: an unlabeled score/badge overlay
        // is invisible to VoiceOver otherwise.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// FR-8.4 *(iPhone and iPad)*: the actions of FR-4.6 reachable by touch
    /// and by name. On the Mac they already have the right-click menu and the
    /// menu bar (FR-8.3), so this button is compiled out there rather than
    /// adding a third redundant affordance to every thumbnail. On touch the
    /// context menu opens only on a long press — a gesture FR-4.6 forbids as
    /// the sole path — so this visible control is that path. In the "Show
    /// Ignored" filter it carries "Un-ignore", which otherwise has no
    /// touch-reachable home at all (FR-4.9).
    @ViewBuilder
    private var actionsMenu: some View {
        #if !os(macOS)
        Menu {
            menu
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .padding(5)
        .accessibilityLabel("Photo actions")
        #endif
    }

    /// FR-8.5: badges and controls that sit *on* a photo are backed by
    /// `.regularMaterial`, never `.glassEffect()`. Two rules meet here. Glass
    /// belongs to the app's own bars and controls and never to the photos, so
    /// the thumbnail stays plain — the material is the content-layer backing
    /// the platform provides for exactly this, not a glass surface. And the
    /// backing has to stay legible over the user's brightest *and* darkest
    /// photos in both appearances: materials take their label colour from the
    /// appearance rather than from the photo behind them, so the thinner
    /// `.ultraThinMaterial` this used to be left dark text over a dark
    /// mountain and light text over a bright sky. `.regularMaterial` is the
    /// thinnest one that stays readable over any photo, and it is used for
    /// every over-photo badge in the app — here and on the duel cards — so
    /// they all look the same.
    @ViewBuilder
    private var badge: some View {
        if isIgnoredMode {
            Image(systemName: "eye.slash.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(.regularMaterial, in: Circle())
                .padding(5)
                .help("You ignored this photo — it stays out of the grid, duels, and the wallpaper album. Its “Un-ignore” action puts it back.")
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
                .background(.regularMaterial, in: Capsule())
                .padding(5)
                .help("Predicted wallpaper appeal, 0–1 — higher scores rank earlier. Learned from your duel choices.")
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open in Photos") {
            CandidateActions.openInPhotos(candidate.localIdentifier, using: openURL)
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
    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "CandidateActions")

    /// Best-effort deep link; the scheme is undocumented but widely used.
    /// Falls back to just opening Photos if navigation isn't supported.
    ///
    /// Handed the caller's `OpenURLAction` rather than reaching for
    /// `NSWorkspace`/`UIApplication`: `openURL` is the one API that opens a URL
    /// on every platform, so the action needs no idea which one it is on. Every
    /// call site is a SwiftUI view or `Commands`, all of which already have the
    /// environment.
    static func openInPhotos(_ localIdentifier: String, using openURL: OpenURLAction) {
        let uuid = localIdentifier.components(separatedBy: "/").first ?? localIdentifier
        guard let url = URL(string: "photos://asset?uuid=\(uuid)") else { return }
        openURL(url)
    }

    /// "Not Wallpaper Material": the human judges this a bad wallpaper on face
    /// value. This does NOT exclude — it records the same absolute bad-quality
    /// verdict the duel's "Both Are Bad" writes, so the photo stays in the
    /// ranking and duels but drags the album-size calibration's quality bar.
    /// It also trains the ranking the same way losing a duel does, pushing
    /// this photo — and others like it — down over time (FR-4.7).
    ///
    /// Training needs the ranker actor (`PreferenceRanker.recordVerdicts`),
    /// which every other call site of this action doesn't otherwise hold a
    /// live instance of (unlike the Duel tab, which already owns one for
    /// choices). Rather than thread a shared ranker through the grid, the
    /// menu bar, and duel-card context menus, this spins up a short-lived
    /// one — the same pattern `AnalysisView` uses for a one-off `prepare()`.
    /// `prepare()` reads the persisted weights file fresh each call, so this
    /// always trains on top of the latest known weights regardless of which
    /// view last wrote them; the one gap is a *concurrently open* Duel tab,
    /// whose own long-lived ranker instance won't notice this write until
    /// its next full `prepare()` (a relaunch) — an existing limitation of
    /// having multiple ranker instances share one weights file, not
    /// something new here.
    ///
    /// Passes `flushSynchronously: true`: this ranker is only reachable from
    /// this `Task` and has no owner once `recordVerdicts` returns, so the
    /// normal debounced flush (whose idle timer captures `self` weakly)
    /// would fire 1.5s later into a `nil` self — the actor having already
    /// deallocated — silently dropping the score-cache write and the
    /// `RankingClock` bump the grid/Export need to re-rank live. See
    /// `PreferenceRanker.recordVerdicts`'s doc comment.
    static func markNotWallpaperMaterial(_ localIdentifier: String, in modelContext: ModelContext) {
        let container = modelContext.container
        Task {
            do {
                let ranker = PreferenceRanker(modelContainer: container)
                try await ranker.prepare()
                try await ranker.recordVerdicts([localIdentifier], isGood: false, flushSynchronously: true)
            } catch {
                log.error("Failed to record bad verdict for \(localIdentifier, privacy: .public): \(error)")
            }
        }
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

    /// Writes both halves of an ignore: the durable `IgnoreRecord` that FR-9.1
    /// carries to the user's other devices, and the `PhotoRecord.isExcluded`
    /// cache the grid, duel and album fetches actually filter on (they use
    /// `#Predicate`s, which cannot join across the two stores). See
    /// `IgnoreRecord` for why the judgment lives apart from the photo.
    private static func setIgnored(_ localIdentifier: String, _ ignored: Bool, in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier }
        )
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        modelContext.insert(IgnoreRecord(photoKey: record.judgmentKey, isIgnored: ignored, timestamp: Date()))
        record.isExcluded = ignored
        try? modelContext.save()
        RankingClock.shared.bump() // grid + export preview + suggestion reload
    }
}

/// Fetches display bitmaps from PhotoKit at a requested size.
nonisolated enum ThumbnailLoader {
    // @concurrent: the synchronous PHAsset.fetchAssets lookup below would
    // otherwise run on the calling view's main actor (a plain `nonisolated`
    // async func doesn't hop off its caller's actor until it actually
    // suspends) — with a full grid that's one blocking PhotoKit call per
    // cell on every tab switch.
    @concurrent
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
