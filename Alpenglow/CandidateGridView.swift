import SwiftUI
import SwiftData
import Photos
import Observation
import CoreGraphics
import os

/// The Library tab's three-way view switch (FR-4.9): top candidates, or
/// either verdict's review list. Named `LibraryView` rather than `View` (the
/// obvious name) because that would collide with SwiftUI's own protocol.
enum LibraryView: String, CaseIterable, Identifiable {
    case library, notWallpaperMaterial, ignored

    var id: String { rawValue }

    /// Full label — for the picker on a wide-enough window and for the View
    /// menu, where "Not Wallpaper Material" reads fine as a whole word.
    var title: String {
        switch self {
        case .library: "Library"
        case .notWallpaperMaterial: "Not Wallpaper Material"
        case .ignored: "Ignored"
        }
    }
}

/// Loads the ranked, deduplicated candidate list off the main actor.
@MainActor
@Observable
final class GridModel {
    /// Each view's contents, and `nil` until that view's first load lands.
    ///
    /// The optionals are load-bearing, not defensive (FR-8.7). An empty array
    /// and "hasn't loaded yet" look identical to a view builder, and the two
    /// review lists used to start as `[]` — so switching to one of them drew
    /// "No Photos Marked" against a list that simply hadn't been read yet, then
    /// replaced it with the real photos a moment later. An empty state that
    /// appears and then vanishes is a transient the user watches flicker, and
    /// the fix is to be able to tell the two apart at the point of decision.
    private(set) var result: FeatureStore.RankedResult?
    private(set) var notWallpaperMaterial: [Candidate]?
    private(set) var ignored: [Candidate]?
    /// True while *any* of the three views is loading — the header's wait
    /// indicator reads this, so switching views is covered by the same
    /// indicator a re-rank is.
    private(set) var isLoading = false
    /// The Library tab's view switch (FR-4.9). Lives here rather than as
    /// view-local `@State` so it has one source of truth reachable both from
    /// `CandidateGridView`'s own picker and from the View menu's Library
    /// commands — the model is published via
    /// `.focusedSceneValue(\.libraryGridModel, self)` below and read back by
    /// `AppCommands` (see AppCommands.swift for the focusedValue plumbing).
    var selection: LibraryView = .library

    private var store: FeatureStore?
    private var pendingReload = false

    /// Loads whichever of the three views (FR-4.9) is selected.
    ///
    /// One entry point for all three rather than a method each, so the loading
    /// flag, the coalescing, and the store are shared: previously only the
    /// ranked view raised `isLoading`, and the two review lists loaded with no
    /// wait indicator anywhere on screen.
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
            // `selection` is re-read each pass, so a view switched during a
            // load is what the coalesced repeat goes on to fetch.
            switch selection {
            case .library:
                result = try? await store.rankedCandidates()
            case .notWallpaperMaterial:
                notWallpaperMaterial = (try? await store.notWallpaperMaterialCandidates()) ?? []
            case .ignored:
                ignored = (try? await store.ignoredCandidates()) ?? []
            }
        } while pendingReload
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

            switch model.selection {
            case .library:
                candidateGrid
            case .notWallpaperMaterial:
                notWallpaperMaterialGrid
            case .ignored:
                ignoredGrid
            }
        }
        .task(id: "\(model.selection.rawValue)|\(RankingClock.shared.version)") {
            // Reloads on appearance and after every duel choice re-trains the
            // ranker; also on switching the Library view (FR-4.9), which the
            // model's own `selection` tells it.
            await model.load(container: modelContext.container)
        }
        // FR-8.3: lets the View menu's Library commands control the same
        // model this view's own picker does.
        .focusedSceneValue(\.libraryGridModel, model)
    }

    @ViewBuilder
    private var candidateGrid: some View {
        if let result = model.result {
            if result.candidates.isEmpty {
                ContentUnavailableView(
                    "No Candidates Yet",
                    systemImage: "photo.stack",
                    description: Text("Run the scan and analysis above — accepted photos appear here, best first.")
                )
            } else {
                grid(result.candidates)
            }
        } else {
            loadingPlaceholder("Loading candidates…")
        }
    }

    @ViewBuilder
    private var notWallpaperMaterialGrid: some View {
        if let marked = model.notWallpaperMaterial {
            if marked.isEmpty {
                ContentUnavailableView(
                    "No Photos Marked",
                    systemImage: "hand.thumbsdown",
                    description: Text("Photos judged poor wallpapers stay in the ranking but sink over time. The toggle here clears the verdict and returns a photo to normal standing.")
                )
            } else {
                grid(marked)
            }
        } else {
            loadingPlaceholder("Loading photos…")
        }
    }

    @ViewBuilder
    private var ignoredGrid: some View {
        if let ignored = model.ignored {
            if ignored.isEmpty {
                ContentUnavailableView(
                    "No Ignored Photos",
                    systemImage: "eye.slash",
                    description: Text("Photos you ignore appear here so you can restore them.")
                )
            } else {
                grid(ignored)
            }
        } else {
            loadingPlaceholder("Loading photos…")
        }
    }

    /// What a view shows before its first load lands — never its empty state,
    /// which would otherwise flash and be replaced (FR-8.7), and never nothing
    /// at all, which FR-4.11 rules out for a wait the user can perceive.
    ///
    /// It is a wait indicator, so it obeys the same delay as the rest: a load
    /// that beats it leaves this area blank for the frame or two it takes, and
    /// the content appears without a spinner having flickered in front of it.
    private func loadingPlaceholder(_ label: LocalizedStringKey) -> some View {
        ProgressView(label)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .shownWhileWaiting()
    }

    private func grid(_ candidates: [Candidate]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
            spacing: 12
        ) {
            ForEach(candidates) { candidate in
                ThumbnailCell(candidate: candidate)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            // The heading names what is actually below it. Each of the three
            // views shows a different slice of the library (FR-4.9), and
            // calling the review lists "Top Candidates" would misdescribe the
            // screen — they are precisely the photos held *out* of the
            // ranking (ignored) or dragging it down (not wallpaper material).
            Text(headingText)
                .font(.headline)

            if let result = model.result, model.selection == .library {
                Text("\(result.candidates.count) of \(result.acceptedCount) accepted · \(result.suppressedCount) near-duplicates hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            libraryViewPicker

            // No manual refresh control (FR-4.5): the grid brings itself up
            // to date for content as well as order via the `.task(id:)` keyed
            // on `RankingClock.shared.version` below, so the only thing left
            // to show here is the loading state while that reload runs.
            //
            // Built unconditionally and handed its state, so the picker just
            // to its left keeps its position instead of being shoved sideways
            // by the spinner's width every time a reload starts (FR-8.7) —
            // and a reload that beats the delay never shows one at all, which
            // covers most of them, since a re-rank of an already-warm store
            // returns almost immediately.
            //
            // `isLoading` alone, with no test on which view is showing: all
            // three load through the same call, and gating this on the ranked
            // view left the two review lists loading with nothing on screen
            // to say so.
            ProgressView()
                .controlSize(.small)
                .shownWhileWaiting(model.isLoading)
        }
    }

    private var headingText: String {
        switch model.selection {
        case .library: "Top Candidates"
        case .notWallpaperMaterial: "Not Wallpaper Material"
        case .ignored: "Ignored Photos"
        }
    }

    /// The three-way Library view switch (FR-4.9). A segmented `Picker` is
    /// the platform idiom for a view-mode switch (Finder's icon/list/column
    /// control in the toolbar), unlike the single on/off `Toggle` this
    /// replaces. "Not Wallpaper Material" is long enough that three full
    /// labels can outgrow an iPhone-width window, so `ViewThatFits` falls
    /// back to a `Menu` — the same pattern `DuelView.controls` uses for its
    /// own width-dependent layout.
    private var libraryViewPicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Library View", selection: Bindable(model).selection) {
                ForEach(LibraryView.allCases) { view in
                    Text(view.title).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            // Without this the picker drifts to the far edge of an iPad
            // window: a `Picker` takes all the width it is offered and
            // pushes its segments apart, which on the Mac's narrower window
            // is invisible but on iPad left the control spanning most of the
            // header, crowding the loading indicator beside it. `fixedSize`
            // holds the picker to its ideal width, which
            // is what FR-4.13 asks of any control and what FR-8.4 needs for
            // this one to be nameable by touch.
            .fixedSize()
            .accessibilityLabel("Library view")

            Menu(model.selection.title) {
                Picker("Library View", selection: Bindable(model).selection) {
                    ForEach(LibraryView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Library view")
        }
    }
}

/// One grid cell: lazily loaded thumbnail with a score badge.
/// Shared by the Library grid and the Export album preview.
struct ThumbnailCell: View {
    let candidate: Candidate
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var thumbnail: CGImage?

    var body: some View {
        tile
            // The verdict toggles and the actions menu sit *outside* `tile`,
            // and so outside its `.accessibilityElement(children: .ignore)`,
            // which would otherwise swallow the only touch path to the photo
            // actions (FR-8.4) and leave VoiceOver unable to reach them.
            .overlay(alignment: .bottomLeading) { verdictToggles }
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
                isIgnored: candidate.isIgnored,
                isNotWallpaperMaterial: candidate.isNotWallpaperMaterial,
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
                    // A whole screen of tiles resolving out of the thumbnail
                    // cache would otherwise blink a spinner each, for a wait
                    // nobody perceives (FR-8.7); only a tile actually held up
                    // — an original still coming down from iCloud — gets one.
                    ProgressView()
                        .controlSize(.small)
                        .shownWhileWaiting()
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

    /// FR-4.14: the two verdict toggles (FR-4.6), as translucent overlay
    /// buttons in the same visual family as the favorite heart at
    /// `.topLeading` — `.regularMaterial` circle backing, `.caption` glyph,
    /// `.plain` button style, the same padding rhythm. One tap or click marks
    /// or unmarks a photo, no context menu or long-press needed, and this
    /// works identically wherever `ThumbnailCell` appears (the Library grid
    /// and the Export preview) because both toggles read `candidate`'s own
    /// flags rather than a mode passed in by the caller. `.regularMaterial`,
    /// not `.glassEffect()` — see `badge`'s doc comment for why (FR-8.5):
    /// the same reasoning applies verbatim to every over-photo control, this
    /// pair included.
    ///
    /// Each button's glyph changes shape (outline → filled) as well as
    /// prominence (`.secondary` → `.primary`), not just colour — required so
    /// the state reads under increase-contrast and for colourblind users
    /// (FR-8.1).
    ///
    /// The verdict toggle is disabled on an ignored photo, and says why.
    /// FR-4.8 takes an ignored photo out of the ranking entirely, and the
    /// ranker only loads entries for `isNature && !isExcluded` records — so a
    /// verdict written against one has nothing to train and nothing to
    /// calibrate, and `PreferenceRanker.recordVerdicts` would silently drop
    /// it for want of an entry. A disabled control that explains itself is
    /// the honest reading of that: the photo is out, un-ignore it first.
    private var verdictToggles: some View {
        HStack(spacing: 6) {
            Button {
                CandidateActions.setNotWallpaperMaterial(candidate.localIdentifier, !candidate.isNotWallpaperMaterial, in: modelContext)
            } label: {
                Image(systemName: candidate.isNotWallpaperMaterial ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.caption)
                    .foregroundStyle(candidate.isNotWallpaperMaterial ? .primary : .secondary)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(candidate.isIgnored)
            .accessibilityLabel(verdictToggleLabel)
            .help(verdictToggleHelp)

            Button {
                CandidateActions.setIgnored(candidate.localIdentifier, !candidate.isIgnored, in: modelContext)
            } label: {
                Image(systemName: candidate.isIgnored ? "eye.slash.fill" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(candidate.isIgnored ? .primary : .secondary)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(candidate.isIgnored ? "Un-ignore this photo" : "Ignore this photo")
            .help(candidate.isIgnored ? "Returns this photo to the grid, duels, and the wallpaper album." : "Ignores this photo — it leaves the grid, duels, and the wallpaper album without teaching the app anything. Right for a good shot you'd rather not see every day.")
        }
        .padding(5)
    }

    /// FR-4.13: the verdict toggle names its own action in words, including
    /// the reason it is unavailable — a disabled icon with no explanation
    /// leaves VoiceOver and touch users with nothing.
    private var verdictToggleLabel: String {
        if candidate.isIgnored {
            "Mark as not wallpaper material, unavailable while this photo is ignored"
        } else if candidate.isNotWallpaperMaterial {
            "Clear not-wallpaper-material verdict"
        } else {
            "Mark as not wallpaper material"
        }
    }

    private var verdictToggleHelp: String {
        if candidate.isIgnored {
            "Ignored photos are out of the ranking entirely — un-ignore this photo to judge it."
        } else if candidate.isNotWallpaperMaterial {
            "Clears the “Not Wallpaper Material” verdict, returning this photo to normal standing."
        } else {
            "Marks this photo as not wallpaper material — a quality judgment the app learns from; it stays in the ranking but sinks over time. For a good photo you just don't want to see, use Ignore instead."
        }
    }

    /// FR-8.4 *(iPhone and iPad)*: the actions of FR-4.6 reachable by touch
    /// and by name. On the Mac they already have the right-click menu and the
    /// menu bar (FR-8.3), so this button is compiled out there rather than
    /// adding a third redundant affordance to every thumbnail. On touch the
    /// context menu opens only on a long press — a gesture FR-4.6 forbids as
    /// the sole path — so this visible control is that path.
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
    ///
    /// Used to show an `eye.slash.fill` marker in place of the score for a
    /// cell in the old "Show Ignored" filter. That branch is gone now that
    /// FR-4.14 puts the ignore toggle itself on every thumbnail: its filled
    /// state already says "ignored" (with a shape change, not just an icon
    /// swap), so a second marker here was redundant, and FR-4.4 wants every
    /// thumbnail — ignored ones included — to show its score.
    private var badge: some View {
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

    /// FR-4.6's three actions, plus FR-4.6's toggle wording: the two verdict
    /// entries read as their reverse once the photo already carries that
    /// verdict ("Not Wallpaper Material" ↔ "Clear Verdict", "Ignore This
    /// Photo" ↔ "Un-ignore"), driven by `candidate`'s own flags. `role:
    /// .destructive` marks only the marking direction — un-ignoring undoes a
    /// decision, which isn't itself destructive.
    @ViewBuilder
    private var menu: some View {
        Button("Open in Photos") {
            CandidateActions.openInPhotos(candidate.localIdentifier, using: openURL)
        }
        Divider()
        Button(candidate.isNotWallpaperMaterial ? "Clear Verdict" : "Not Wallpaper Material") {
            CandidateActions.setNotWallpaperMaterial(candidate.localIdentifier, !candidate.isNotWallpaperMaterial, in: modelContext)
        }
        // Same reason the overlay toggle disables here — see `verdictToggles`.
        .disabled(candidate.isIgnored)
        if candidate.isIgnored {
            Button("Un-ignore") {
                CandidateActions.setIgnored(candidate.localIdentifier, false, in: modelContext)
            }
        } else {
            Button("Ignore This Photo", role: .destructive) {
                CandidateActions.setIgnored(candidate.localIdentifier, true, in: modelContext)
            }
        }
    }

    /// Folds in both verdicts, each only when present, e.g. "Score 0.72,
    /// favorite, not wallpaper material, ignored".
    private var accessibilityLabel: String {
        let score = candidate.displayScore.formatted(.number.precision(.fractionLength(2)))
        var parts = ["Score \(score)"]
        if candidate.isFavorite { parts.append("favorite") }
        if candidate.isNotWallpaperMaterial { parts.append("not wallpaper material") }
        if candidate.isIgnored { parts.append("ignored") }
        return parts.joined(separator: ", ")
    }
}

/// Context-menu actions shared by every image shown in the app.
@MainActor
enum CandidateActions {
    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "CandidateActions")

    /// FR-4.6's "Open in Photos". Best-effort deep link; the scheme is
    /// undocumented but widely used.
    ///
    /// Handed the caller's `OpenURLAction` rather than reaching for
    /// `NSWorkspace`/`UIApplication`: `openURL` is the one API that opens a URL
    /// on every platform, so the action needs no idea which one it is on. Every
    /// call site is a SwiftUI view or `Commands`, all of which already have the
    /// environment.
    ///
    /// The fallback is the whole point of the completion handler, and it is
    /// what was missing: `photos://asset?uuid=` opens the photo on the Mac,
    /// but iOS registers no handler for the scheme at all, so the call was
    /// refused and — with the result thrown away — the command did nothing
    /// whatsoever. That is what device vetting found on the iPad, and an
    /// action named in a menu and a context menu (FR-8.3, FR-8.4) may not
    /// silently do nothing.
    ///
    /// Measured 2026-08-08 on iOS 27, which is the only way to know since none
    /// of this is documented: `photos://asset?uuid=…` and even a bare
    /// `photos://` both fail to open (`LSApplicationWorkspaceErrorDomain` 115,
    /// no handler), while `photos-redirect://` opens Photos. There is no
    /// public way to reach a *particular* asset on iOS, so the app itself is
    /// the honest second choice. Both outcomes are logged, because the only
    /// other way to tell them apart is to watch the screen.
    static func openInPhotos(_ localIdentifier: String, using openURL: OpenURLAction) {
        let uuid = localIdentifier.components(separatedBy: "/").first ?? localIdentifier
        guard let asset = URL(string: "photos://asset?uuid=\(uuid)") else { return }
        openURL(asset) { openedAsset in
            if openedAsset {
                log.debug("Opened the photo in Photos")
                return
            }
            guard let app = URL(string: "photos-redirect://") else { return }
            openURL(app) { openedApp in
                if openedApp {
                    log.notice("No handler for photos://asset — opened the Photos app instead")
                } else {
                    log.error("Nothing on this device would open Photos")
                }
            }
        }
    }

    /// Why every verdict-writing action below spins up its own short-lived
    /// `PreferenceRanker` rather than sharing one: training needs the ranker
    /// actor (`recordVerdicts`/`clearVerdicts`), which every call site here
    /// doesn't otherwise hold a live instance of (unlike the Duel tab, which
    /// already owns one for choices). Rather than thread a shared ranker
    /// through the grid, the menu bar, and duel-card context menus, each
    /// action spins one up — the same pattern `AnalysisView` uses for a
    /// one-off `prepare()`. `prepare()` reads the persisted weights file
    /// fresh each call, so this always trains on top of the latest known
    /// weights regardless of which view last wrote them. A concurrently open
    /// Duel tab is not a gap (FR-5.10): the write bumps `RankingClock`, the
    /// Duel tab's `.task(id: RankingClock.shared.version)` calls
    /// `PreferenceRanker.reload()`, and its judgment-count check detects the
    /// foreign write and re-`prepare()`s before the next pair is drawn.
    ///
    /// And why each passes `flushSynchronously: true`: that ranker is only
    /// reachable from its own `Task` and has no owner once the call returns,
    /// so the normal debounced flush (whose idle timer captures `self`
    /// weakly) would fire 1.5s later into a `nil` self — the actor having
    /// already deallocated — silently dropping the score-cache write and the
    /// `RankingClock` bump the grid/Export need to re-rank live. See
    /// `PreferenceRanker.recordVerdicts`'s doc comment.

    /// "Not Wallpaper Material": the human judges this a bad wallpaper on face
    /// value. This does NOT exclude — it records the same absolute bad-quality
    /// verdict the duel's "Both Are Bad" writes, so the photo stays in the
    /// ranking and duels but drags the album-size calibration's quality bar.
    /// It also trains the ranking the same way losing a duel does, pushing
    /// this photo — and others like it — down over time (FR-4.7). See the
    /// short-lived-ranker rationale above.
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

    /// Reverses `markNotWallpaperMaterial`: appends a clearing verdict so the
    /// photo returns to normal standing, as if it had never been marked
    /// (FR-4.7). Mirrors `markNotWallpaperMaterial` exactly — see the
    /// short-lived-ranker rationale above, except for the flush: clearing
    /// rebuilds the weights from scratch (SGD cannot un-apply a step), and
    /// that rebuild already writes the whole score cache and bumps
    /// `RankingClock` itself, so there is nothing left to flush here.
    static func clearNotWallpaperMaterial(_ localIdentifier: String, in modelContext: ModelContext) {
        let container = modelContext.container
        Task {
            do {
                let ranker = PreferenceRanker(modelContainer: container)
                try await ranker.prepare()
                try await ranker.clearVerdicts([localIdentifier])
            } catch {
                log.error("Failed to clear bad verdict for \(localIdentifier, privacy: .public): \(error)")
            }
        }
    }

    /// The "Not Wallpaper Material" toggle's single entry point (FR-4.6):
    /// every call site — the thumbnail overlay, the context/actions menu, the
    /// Photo menu bar item, the duel card — routes through here rather than
    /// picking `markNotWallpaperMaterial`/`clearNotWallpaperMaterial` itself.
    static func setNotWallpaperMaterial(_ localIdentifier: String, _ marked: Bool, in modelContext: ModelContext) {
        if marked {
            markNotWallpaperMaterial(localIdentifier, in: modelContext)
        } else {
            clearNotWallpaperMaterial(localIdentifier, in: modelContext)
        }
    }

    /// "Ignore This Photo": fully drop it from the grid, duels, calibration,
    /// and (on next sync) the wallpaper album. Reviewable/reversible via the
    /// Library tab's Ignored view (FR-4.9). Sets the ignored flag (stored as
    /// `isExcluded` — see PhotoRecord).
    static func ignore(_ localIdentifier: String, in modelContext: ModelContext) {
        setIgnored(localIdentifier, true, in: modelContext)
    }

    /// Writes both halves of an ignore: the durable `IgnoreRecord` that FR-9.1
    /// carries to the user's other devices, and the `PhotoRecord.isExcluded`
    /// cache the grid, duel and album fetches actually filter on (they use
    /// `#Predicate`s, which cannot join across the two stores). See
    /// `IgnoreRecord` for why the judgment lives apart from the photo.
    ///
    /// Internal, not `private`: this is the toggle entry point every call
    /// site uses directly (`CandidateActions.setIgnored(id, !candidate.isIgnored, in:
    /// context)`), the same shape `setNotWallpaperMaterial` gives its verdict.
    static func setIgnored(_ localIdentifier: String, _ ignored: Bool, in modelContext: ModelContext) {
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
