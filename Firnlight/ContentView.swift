import SwiftUI
import SwiftData
import Photos
#if !os(macOS)
import UIKit
#endif

/// Which of the three tabs is selected (FR-8.1: restore the active tab across
/// launches). A stable string raw value, not an `Int` index, so a future
/// reordering of the tabs can't silently jump the user to the wrong one.
private enum AppTab: String {
    case library, duel, export
}

/// FR-8.12's alert channel for actions that have no view of their own to
/// report into.
///
/// The Duel tab's judgments already report failure where they happen: the
/// duel *is* the surface that took the action, so `DuelModel` queues the
/// message and its own alert shows it. Every other route to the same
/// judgments — the thumbnail overlay, a context menu, the Photo menu bar —
/// is a fire-and-forget static call in `CandidateActions` with no view and
/// no error channel, so a failed verdict there used to reach the log alone
/// while the interface carried on as though the photo had been marked.
/// FR-8.12 admits no such asymmetry: the same failure, taken by a different
/// route, must be as visible.
///
/// Shared and app-level rather than passed down, because those call sites
/// span three surfaces (grid, context menu, menu bar commands) with no view
/// in common below the window; `ContentView` presents it once for all of
/// them, and is always mounted whichever tab is selected. The queue, the
/// deferred pop and the double-dismissal guard are `DuelModel.dismissError`'s
/// exactly — see there for why each is needed; a second failure arriving
/// while the first is on screen must still get its own turn rather than be
/// discarded by the first one's dismissal.
@MainActor
@Observable
final class ActionFailures {
    static let shared = ActionFailures()

    private(set) var messages: [String] = []
    private var isDismissing = false

    private init() {}

    func report(_ message: String) {
        messages.append(message)
    }

    func dismissFirst() {
        guard !messages.isEmpty, !isDismissing else { return }
        isDismissing = true
        Task { @MainActor in
            if !messages.isEmpty {
                messages.removeFirst()
            }
            isDismissing = false
        }
    }
}

struct ContentView: View {
    /// FR-8.12: see `ActionFailures`. Presented here because the actions that
    /// feed it belong to no single tab.
    private let actionFailures = ActionFailures.shared

    @State private var authorization = PhotoLibraryAuthorization()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// The pipeline that keeps the app current with the library (FR-2.7),
    /// owned here rather than by the Library tab that displays it: a `TabView`
    /// only builds the *selected* tab, and catching up has to happen whichever
    /// tab the user was last on. It is also what the tab's own progress reads,
    /// so a launch catch-up and a change-driven one are visibly the same run.
    @State private var catchUp = LibraryCatchUp()

    /// FR-5.12: owned here, not by `DuelView`, for exactly the reason
    /// `catchUp` above is — `TabView` only builds the *selected* tab, and on
    /// this "Tab" value-based API that's not just a lazy first build but a
    /// genuine unmount/remount on every switch away and back (see
    /// `AppCommands.duelUndoTarget`'s doc comment, which relies on that
    /// unmount to know when `DuelView` isn't visible). A `DuelModel` owned
    /// by `DuelView` itself as its own `@State` would be torn down and
    /// recreated on every such switch, silently discarding `canUndo` /
    /// `pendingUndo` — exactly the correction offer FR-5.12 requires survive
    /// "looking elsewhere in the app and back". Owning it at the `TabView`'s
    /// level instead ties its lifetime to the window (FR-1.7), same as
    /// `catchUp`, so the offer survives every tab switch and is cleared only
    /// by what FR-5.12 itself names: the next judgment, or a relaunch.
    @State private var duelModel = DuelModel()

    /// FR-10.8. Shared with the settings switch that turns it on and off — see
    /// `UpdateCheck.shared`.
    private let updates = UpdateCheck.shared
    /// The one time the app puts the question. Raised once the library is
    /// usable rather than at the first frame, so a first launch shows the
    /// Photos-access screen alone instead of stacking an unrelated alert on
    /// top of it.
    @State private var isAskingAboutUpdates = false

    // FR-8.1: persist which tab the user was on. `@AppStorage`, not the more
    // idiomatic `@SceneStorage`, because `@SceneStorage` restores through
    // AppKit's window-restoration machinery — it needs a window to still
    // exist, or be reconstructable, across launches. Firnlight is a
    // single-window app that quits when its window closes (FR-1.7), so there
    // is no surviving window state for `@SceneStorage` to hang its restore
    // off; in practice it doesn't come back on the next launch. `@AppStorage`
    // is a flat UserDefaults value with no dependency on window restoration,
    // so it reliably survives quit → relaunch.
    @AppStorage("selectedTab") private var selectedTab = AppTab.library

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "photo.on.rectangle.angled", value: AppTab.library) {
                tabContent { LibraryTab(authorization: authorization, catchUp: catchUp, updates: updates) }
            }
            Tab("Duel", systemImage: "rectangle.split.2x1", value: AppTab.duel) {
                tabContent { DuelView(model: duelModel, authorization: authorization) }
            }
            Tab("Export", systemImage: "square.and.arrow.up", value: AppTab.export) {
                tabContent { ExportView() }
            }
        }
        // No minimum size here: on the Mac the window owns that (see
        // FirnlightApp), and on iPhone the screen is narrower than any floor
        // worth setting.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // Pick up grants made in System Settings while we were in the
            // background (FR-1.3), and narrowings made the same way (FR-1.8).
            authorization.refresh()
            // Pick a run back up that the system ended while the app was away,
            // or one whose deferred iCloud work may now be possible (FR-3.4,
            // FR-3.6). Deliberately *not* a whole catch-up: the library
            // reports its own changes (see `LibraryCatchUp`), so walking it
            // again on every switch back to the app would be work with a known
            // answer.
            catchUp.resumeIfWorkRemains()
        }
        // FR-2.7: with access to the whole library, the app catches up on its
        // own — at launch and from then on as Photos reports changes — with
        // nothing for the user to press.
        //
        // Attached to the TabView, not to the Library tab that shows the
        // progress, because `TabView` only builds the *selected* tab: while
        // this lived in `LibraryTab.task`, FR-8.1 restoring the user to Export
        // or Duel meant the tab never mounted and the catch-up silently never
        // ran. It is unconditional, so its trigger has to hang off something
        // that exists on every launch regardless of tab.
        //
        // `.task(id:)` on the authorization state rather than a plain `.task`:
        // the pipeline must also start the moment the user grants access
        // without relaunching (FR-1.3), which is exactly when this id flips —
        // and must stand down the moment access is narrowed to a selection
        // (FR-1.8), which is when it flips back.
        //
        // Nothing about *where* the work runs changes: the scan yields
        // cooperatively and analysis runs in its own actor off the main thread,
        // so the rest of the app stays live behind their progress (FR-8.2), and
        // switching to Library mid-run picks up the same observable models
        // already counting up (FR-2.4, FR-4.11).
        .task(id: authorization.isAuthorized) {
            guard authorization.isAuthorized else {
                await catchUp.end()
                return
            }
            // Deliberately no album work here. Recovering an interrupted sync
            // (FR-6.8) is offered in the Export tab instead of done on launch,
            // because these devices share one album and FR-6.10 forbids
            // changing it unattended — see WallpaperAlbumSync.restoreInterruptedSync.
            catchUp.begin(context: modelContext, authorization: authorization)

            // FR-10.8, in the order the requirement puts it: agreement first,
            // then — and only then — a check.
            if updates.hasBeenAsked {
                await updates.checkIfAgreed()
            } else {
                isAskingAboutUpdates = true
            }
        }
        .alert("Let Firnlight check for new releases?", isPresented: $isAskingAboutUpdates) {
            // Both answers are final, which is why neither is worded as "not
            // now": the question is asked once, and the switch in Settings is
            // where either answer is changed later.
            Button("Don’t Check") { updates.setConsent(false) }
            Button("Check for Releases") { updates.setConsent(true) }
        } message: {
            Text("Firnlight is downloaded from GitHub rather than an app store, so it can only tell you a newer version exists by asking GitHub. It sends nothing about you or your library, and you can change this in Settings.")
        }
        // FR-8.12: whatever a grid, context-menu or menu-bar action failed to
        // do, said in words rather than left to the log. `isPresented` bound
        // to "the queue is non-empty", with the dismissal popping exactly one
        // message — the same shape and the same reasons as the Duel tab's
        // alert.
        .alert(
            "Couldn’t Record That",
            isPresented: Binding(
                get: { !actionFailures.messages.isEmpty },
                set: { if !$0 { actionFailures.dismissFirst() } }
            )
        ) {
            Button("OK") {} // the binding above does the popping
        } message: {
            Text(actionFailures.messages.first ?? "")
        }
    }

    /// FR-8.1 (HIG, tab-based apps): every tab's own content, on iOS, sits
    /// inside a `GeometryReader` here — before, not inside, its own
    /// `NavigationStack` (`LibraryTab`, `DuelView`, and `ExportView` each
    /// wrap themselves; see their own `body`).
    ///
    /// Measured, not guessed (2026-08-23, iOS 27 simulator): a
    /// `NavigationStack` nested directly inside a `Tab`'s content costs every
    /// descendant `ScrollView` the floating tab bar's own bottom safe-area
    /// accommodation — screenshot-confirmed with the Library tab's Analysis
    /// stat rows and the Export tab's "Create Album" button and notice text
    /// rendering directly under the glass tab bar (FR-8.5: "Nothing the user
    /// needs to see is half-hidden under a bar").
    ///
    /// A prior version of this fix constrained `content()`'s frame to
    /// `proxy.size.height - proxy.safeAreaInsets.bottom` — subtracting the
    /// tab bar's own inset a *second* time. Debug-overlay measurement showed
    /// why: at this `GeometryReader` (a `Tab`'s direct content, ahead of
    /// `NavigationStack`), `proxy.size.height` is *already* the screen's
    /// content height short of the tab bar's own footprint — this
    /// `GeometryReader` sits downstream of `TabView`'s own accounting for
    /// the floating bar, which a `GeometryReader` placed as a sibling of the
    /// whole `TabView` does not yet reflect (confirmed by comparing both
    /// readings side by side). Subtracting `safeAreaInsets.bottom` again
    /// shrank the frame by the bar's height *twice*, which is what produced
    /// 838cbd4's regression: a dead gap roughly the bar's own height, with
    /// content — the Library tab's per-reason `Grid` and the Export tab's
    /// "Create Album" button — clipped well short of it instead of merely
    /// stopping short of the bar.
    ///
    /// The corrected fix uses `proxy.size.height` as-is (no further
    /// subtraction) and adds `.clipped()`: `NavigationStack`, even given an
    /// already-correct proposed height, does not itself clip a descendant
    /// `ScrollView` to it — screenshot-confirmed as a sliver of the last row
    /// bleeding through the glass tab bar without `.clipped()` — so this
    /// enforces the boundary `proxy.size.height` already gets right. At
    /// rest, content stops at (or a hair short of) the tab bar with no dead
    /// gap; content taller than that still scrolls to reveal the rest —
    /// confirmed for the Library tab by seeding its persisted scroll offset
    /// (`UserDefaults` key `libraryScrollOffsetY`) past the fold and
    /// relaunching: the full per-reason `Grid` and the tab's remaining cards
    /// render, ending flush with (not under) the bar. Root cause of the
    /// double-accounting not otherwise established — nothing in the 27
    /// SDK's release notes or header comments documents it — so this remains
    /// a measured, reproducible workaround for a specific beta build, not an
    /// explained one; revisit on the next Xcode 27 beta or GA release, and
    /// re-verify by screenshot before trusting it.
    ///
    /// No-op on macOS, which has neither a floating tab bar nor this bug.
    @ViewBuilder
    private func tabContent<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        #if os(macOS)
        content()
        #else
        GeometryReader { proxy in
            content()
                .frame(height: proxy.size.height, alignment: .top)
                .clipped()
        }
        #endif
    }
}

/// Library tab: Photos authorization, then the pipeline's progress and the
/// ranked grid.
private struct LibraryTab: View {
    let authorization: PhotoLibraryAuthorization
    /// Owned by `ContentView`, because catching up runs from outside any tab.
    /// This tab renders its progress, so a catch-up the launch started and one
    /// a library change started are visibly the same run.
    let catchUp: LibraryCatchUp
    let updates: UpdateCheck

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// `CandidateGridView`'s own load state (FR-8.7's honesty requirement,
    /// see `pendingRestoreTargetY`'s doc comment): the growth-driven restore
    /// below needs a real "is the grid still loading" signal, not just "has
    /// layout gone quiet for a while".
    ///
    /// Owned here rather than read back via `@FocusedValue(\.libraryGridModel)`
    /// (which is what `AppCommands` uses, and what an earlier version of this
    /// fix relied on too): `.focusedSceneValue` only publishes while this
    /// tab's view is mounted *and the scene holds focus* (see
    /// AppCommands.swift's doc comment) — not guaranteed during a slow or
    /// backgrounded scan, which is exactly when this check matters most. With
    /// the model owned here and handed down to `CandidateGridView`, it's live
    /// state present for the whole time this tab is showing, focus or no.
    @State private var gridModel = GridModel()

    // FR-8.1: restore roughly where the user had scrolled to. Seeded from the
    // persisted vertical offset at view-creation time, so SwiftUI applies it
    // as the ScrollView's *initial* position once content lays out — there's
    // no separate "wait for the grid, then scroll" step to get right.
    //
    // Fidelity trade-off, deliberate: this restores a raw pixel offset, not a
    // specific photo's position. The Library tab's content is the pipeline
    // cards followed by the ranked grid, and the grid re-orders
    // itself between launches as duels retrain the ranking (FR-4.5) — so a
    // pixel-perfect "same photo under the cursor" restore is impossible
    // anyway (the content at that offset isn't guaranteed to be the same). An
    // approximate return to the same scrolled region is what FR-8.1 asks for
    // and what this delivers; a per-item anchor would be more precise for the
    // grid specifically but couldn't survive the cards above it changing
    // height (e.g. a summary appearing) between launches either.
    @State private var scrollPosition = ScrollPosition(
        y: CGFloat(UserDefaults.standard.double(forKey: "libraryScrollOffsetY"))
    )
    /// Tracks the live offset so it can be written out once, at a natural
    /// checkpoint, rather than on every scroll-geometry callback. Seeded from
    /// the same persisted value as `scrollPosition`, so a quit before the
    /// first scroll-geometry callback re-persists the restored offset instead
    /// of clobbering it with 0.
    @State private var currentScrollOffsetY = CGFloat(UserDefaults.standard.double(forKey: "libraryScrollOffsetY"))

    /// FR-8.5: the restore above is a *one-shot* `ScrollPosition(y:)`, applied
    /// once SwiftUI first lays out this `ScrollView`. Measured (2026-08-23,
    /// iOS 27 simulator, via a temporary `onScrollGeometryChange` debug log,
    /// since removed): `CandidateGridView`'s own ranked-candidate load lands
    /// *after* that first layout pass, growing `contentSize.height` in
    /// several steps. Re-issuing the same absolute-`y` target on every one of
    /// those steps (an earlier version of this fix) made no difference — a
    /// seeded `libraryScrollOffsetY` anywhere from 500 up to the point where
    /// SwiftUI stopped honoring it at all settled at the same ~377pt
    /// `contentOffset` even once the grid had fully loaded, which is well
    /// short of the ~610pt `contentSize.height - containerSize.height` says
    /// should be reachable. `ScrollPosition(y:)` against a `LazyVStack`-based
    /// `ScrollView`'s own reported geometry is not to be trusted at this
    /// content size here on the 27 beta; asking for `ScrollPosition(edge:
    /// .bottom)` instead — the ScrollView's own idea of its real end, not our
    /// arithmetic — reached measurably further (~494pt) and, screenshot-
    /// confirmed, cleared "No Candidates Yet"'s full two-line description of
    /// the tab bar. This is what left that description permanently under the
    /// bar at the reachable maximum (FR-8.5: "Nothing the user needs to see
    /// is half-hidden under a bar").
    ///
    /// Fix: keep re-issuing the persisted absolute target while
    /// `contentSize.height` is still growing (for fidelity — most restores
    /// land well short of any edge, and should return to the same *region*,
    /// not snap to the bottom). Once growth has been quiet for a short debounce
    /// window, if the live offset still falls short of that target, that is
    /// treated as *maybe* the target having been at or past the content's true
    /// end when it was saved — but 250ms of layout quiet is a debounce on
    /// churn, not a load-completion signal: a slow scan can space growth
    /// events further apart than that even while still mid-load, so the
    /// window elapsing doesn't by itself mean the grid is done. The fallback
    /// therefore also checks `gridModel.isLoading`: while it reads `true`,
    /// this pass backs off and leaves `pendingRestoreTargetY` set for the
    /// *next* growth event's debounce to re-examine, rather than finishing
    /// against a `contentSize` that is still short of final and snapping to
    /// an intermediate "bottom" the user never scrolled to. Only once loading
    /// has genuinely settled does a persisting shortfall get resolved with
    /// `ScrollPosition(edge: .bottom)`, which lands wherever the *current*
    /// content's real end actually is, not wherever the arithmetic above says
    /// it should be.
    ///
    /// Separately (FR-8.7): every re-application of the target below is only
    /// ever the app restoring what the user already had, never a jump away
    /// from where they are now — so it stops the instant the user starts
    /// scrolling. `onScrollPhaseChange` below clears `pendingRestoreTargetY`
    /// as soon as a `.tracking` phase (the user's finger actually driving the
    /// content) is observed, which both stops any further re-application and
    /// invalidates the in-flight debounce `Task` via `restoreGeneration`, so
    /// a scan that is still growing content minutes into a scan can never
    /// yank a scrolling user back to the saved offset.
    @State private var pendingRestoreTargetY: CGFloat? = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "libraryScrollOffsetY"))
        return saved > 0 ? saved : nil
    }()
    /// Invalidates a stale debounce `Task` when a newer content-size change
    /// supersedes it, so only the *last* growth step's timer ever fires.
    @State private var restoreGeneration = 0

    /// FR-8.1 (HIG, tab-based apps): iPhone and iPad get a `NavigationStack`
    /// with this tab's own title, matching `ExportView` and `DuelView`. That
    /// `NavigationStack` sits inside `ContentView.tabContent`'s frame-and-
    /// `.clipped()`-constrained `GeometryReader`, which is what keeps
    /// `libraryContent`'s `ScrollView` clear of the floating tab bar — see
    /// that function's doc comment for the measured, reproducible SDK-27-
    /// beta bug behind it. The Mac is untouched: no bottom bar there to
    /// establish hierarchy against, and it already has its menu bar
    /// (FR-8.3).
    var body: some View {
        #if os(macOS)
        libraryContent
        #else
        NavigationStack {
            libraryContent
                .navigationTitle("Library")
        }
        #endif
    }

    @ViewBuilder
    private var libraryContent: some View {
        if authorization.isAuthorized {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 20) {
                        if case .available(let version, let url) = updates.availability {
                            updateNotice(version: version, url: url)
                        }
                        LibraryStatusView(catchUp: catchUp)
                        AnalysisView(model: catchUp.analysis, scanToken: scanCompletionToken)
                    }
                    .frame(maxWidth: 560)

                    CandidateGridView(model: gridModel)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                currentScrollOffsetY = newValue
            }
            // See `pendingRestoreTargetY`'s doc comment: keeps nudging the
            // one-shot restore toward its target as the grid's own async
            // load grows the content, then — once growth has settled and the
            // live offset still falls short — asks for the ScrollView's own
            // real bottom edge rather than trusting the arithmetic above.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                guard let target = pendingRestoreTargetY else { return }
                scrollPosition = ScrollPosition(y: target)
                restoreGeneration += 1
                let myGeneration = restoreGeneration
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard myGeneration == restoreGeneration, pendingRestoreTargetY != nil else { return }
                    // Quiet layout isn't the same thing as "done loading" —
                    // see `pendingRestoreTargetY`'s doc comment. Back off and
                    // let the next growth step's debounce re-examine.
                    if gridModel.isLoading { return }
                    pendingRestoreTargetY = nil
                    if currentScrollOffsetY < target - 1 {
                        scrollPosition = ScrollPosition(edge: .bottom)
                    }
                }
            }
            // FR-8.7: the user's own scroll always wins over the restore —
            // see `pendingRestoreTargetY`'s doc comment. `.tracking` alone
            // (an earlier version of this guard) only covers a drag or
            // flick; user-driven motion that never tracks — a status-bar
            // tap-to-top, or keyboard/VoiceOver-driven scrolling — passed
            // straight through it, leaving a later growth event free to yank
            // that position back to the restore target. `ScrollPhase
            // .isScrolling` is true for every non-idle phase (`.tracking`,
            // `.interacting`, `.decelerating`, `.animating`), which covers
            // all of those. Confirmed self-safe (2026-08-23, iOS 27
            // simulator, via a temporary debug log on this same hook, since
            // removed): the restore's own writes below — both the plain
            // `ScrollPosition(y:)` re-application and the `edge: .bottom`
            // fallback — never move the phase off `.idle`, so this can't
            // cancel itself the way checking `.animating` alone might risk
            // for an *animated* programmatic scroll.
            .onScrollPhaseChange { _, newPhase in
                if newPhase.isScrolling, pendingRestoreTargetY != nil {
                    pendingRestoreTargetY = nil
                    restoreGeneration += 1
                }
            }
            // Persist on leaving .active rather than on every scroll frame:
            // backgrounding or, for this quit-on-close app (FR-1.7), quitting
            // is exactly when "where the user left off" needs to be durable,
            // and it's a tiny fraction of the writes a per-frame save would
            // cost. (Its own watcher — ContentView's FR-1.3 watcher fires on
            // the opposite transition, for authorization.)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    UserDefaults.standard.set(Double(currentScrollOffsetY), forKey: "libraryScrollOffsetY")
                }
            }
            // FR-8.3: lets the menu bar's Stop and Resume act on the same run
            // this tab's own control does. Published only in this authorized
            // branch, so the commands are disabled for free whenever the whole
            // library isn't available — see AppCommands.swift.
            .focusedSceneValue(\.libraryCommandTarget, LibraryCommandTarget(
                analysisModel: catchUp.analysis,
                modelContext: modelContext
            ))
        } else {
            authorizationPrompt
        }
    }

    /// FR-10.8: a newer release exists, and here is where to get it.
    ///
    /// Only ever drawn when the user has agreed to the check (nothing else can
    /// produce an `.available`), and only in the Library tab — the app's first
    /// screen, and one place rather than three saying the same thing (FR-8.10).
    /// It arrives and stays, which FR-8.7 allows to take room, and it sits
    /// above content rather than above a control anybody was reaching for.
    private func updateNotice(version: String, url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true) // decorative — the text beside it carries the meaning (FR-4.13)
            Text("Firnlight \(version) is available. You have \(AppIdentity.version).")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Get It…") { openURL(url) }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Non-nil once a catch-up has finished; value changes when results change.
    private var scanCompletionToken: Int? {
        if case .finished(let candidates, _, let newlyAdded, let editedQueued, let removed) = catchUp.scanner.outcome {
            candidates &+ newlyAdded &+ editedQueued &+ removed
        } else {
            nil
        }
    }

    private var authorizationPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.rectangle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true) // decorative — statusMessage below carries the actual state (FR-4.13)
                .help("Firnlight can't read your Photos library yet — grant access to start finding wallpapers.")

            Text("Photos Access")
                .font(.title2.bold())

            Text(statusMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            switch authorization.status {
            case .notDetermined:
                Button("Grant Access to Photos") {
                    Task { await authorization.request() }
                }
                .buttonStyle(.borderedProminent)
            case .denied, .limited:
                // `.limited` shares the button because it shares the remedy:
                // there is no API to re-prompt for full access or to widen a
                // selection (see `PhotoLibraryAuthorization.settingsURL`), so
                // the privacy settings are the only route from a selection to
                // the whole library (FR-1.8).
                //
                // `.restricted` (parental controls/MDM) has no button here:
                // Privacy Settings can't grant it — only the managing admin
                // can — so offering the same shortcut would be a dead end.
                // `statusMessage` above already explains why.
                Button("Open Privacy Settings") {
                    openPrivacySettings()
                }
            default:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusMessage: String {
        switch authorization.status {
        case .notDetermined:
            "Firnlight needs to read your photo library to find wallpaper-worthy nature photos. Everything stays on your device."
        case .authorized:
            "Access granted."
        case .limited:
            // FR-1.8: a selection is not a smaller library, it is a different
            // job the app can’t do — it can’t tell a photo you deleted from
            // one you didn’t select, and Photos won’t let it maintain an album
            // at all. Saying so beats appearing to work.
            #if os(macOS)
            "Firnlight only has access to selected photos, which isn’t enough to keep the wallpaper album or notice photos you delete. Allow access to all photos in System Settings → Privacy & Security → Photos."
            #else
            "Firnlight only has access to selected photos, which isn’t enough to keep the wallpaper album or notice photos you delete. Allow access to all photos in Settings."
            #endif
        case .denied:
            // The app holding privacy permissions has a different name on each
            // platform, and pointing the user at the wrong one is the whole
            // point of this message getting it right.
            #if os(macOS)
            "Access denied. Enable Photos access in System Settings to continue."
            #else
            "Access denied. Enable Photos access in Settings to continue."
            #endif
        case .restricted:
            "Photos access is restricted on this device and can't be granted."
        @unknown default:
            "Unknown authorization status."
        }
    }

    /// FR-1.2's shortcut into the platform's own privacy settings. The
    /// per-platform destination lives on `PhotoLibraryAuthorization`; opening
    /// it is the same `openURL` on both platforms.
    private func openPrivacySettings() {
        guard let url = PhotoLibraryAuthorization.settingsURL else { return }
        openURL(url)
    }
}

/// What the app is doing about the library, and what it last found (FR-2.4).
///
/// There is no control in here, and that is the requirement rather than an
/// omission: FR-2.7 says the app is always current and that there is no
/// re-scan, "because there is nothing a re-scan would find that the app has
/// not already found". What replaced the button is `LibraryCatchUp` — the app
/// catches up at launch and follows the library's own change notifications
/// from then on. So this card reports, and reporting is all it does.
private struct LibraryStatusView: View {
    let catchUp: LibraryCatchUp

    private var scanner: LibraryScanner { catchUp.scanner }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // FR-8.10/FR-4.13: named "Library Scan", not "Library" — this
                // card sits directly under the Library tab's own navigation
                // title on iPhone and iPad (FR-8.1), and two headings reading
                // "Library" in the same screen is one heading too many for
                // one thing. "Library Scan" also does what a heading should:
                // it says what this specific card covers (catching up with
                // the library, FR-2.4) rather than repeating the tab's own
                // name, matching how the "Vision Analysis" card beneath it is
                // already named for its own job rather than the tab's.
                Text("Library Scan")
                    .font(.headline)

                // Fixed order, every phase: blurb, activity group, outcome.
                // Only `outcome`, at the bottom, is allowed to change this
                // card's height (FR-8.7) — `progressRow` and
                // `placeNameLookupRow` each fade by opacity rather than
                // being inserted/removed, so their combined slot's height
                // never changes either.
                //
                // FR-1.5's one network exception is named here, not left for
                // the user to discover on their own: an earlier revision of
                // this sentence claimed "nothing leaves your device" outright,
                // which stopped being true the moment place names started
                // being looked up over the network.
                Text("Firnlight keeps up with your library on its own, watching for photos added, edited or deleted. It looks for high-resolution landscape photos worth considering as wallpapers — metadata only. The one exception: where a photo has a location and your network allows it, Firnlight asks Apple's maps service what that place is called, telling it nothing else.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Grouped tightly together, not two independent rows each
                // carrying this VStack's outer 12pt spacing: `progressRow`
                // and `placeNameLookupRow` toggle independently (scanning,
                // and place-name lookups pending, are unrelated states),
                // and either one can be the only one showing while the
                // other's reserved slot sits empty. At the outer spacing, an
                // empty slot next to visible text read as a stray gap in
                // the card (observed on a real library: scanning had
                // finished but lookups were still pending, so the paragraph
                // was followed by an empty progress-bar-sized hole before
                // the visible place-name line). Tight internal spacing
                // instead — matching `progressRow`'s own bar-to-caption
                // spacing — reads as one "current activity" unit with
                // between zero and two active lines, never as a gap in the
                // middle of unrelated content, while changing nothing about
                // either row's own reservation or fade (FR-8.7 still holds:
                // neither row's slot resizes when its own state flips).
                VStack(alignment: .leading, spacing: 4) {
                    progressRow
                    placeNameLookupRow
                }

                outcome
            }
            .padding(8)
            // Matches `AnalysisView`'s card — see the note there for why the
            // stretch has to be applied inside the `GroupBox` rather than to
            // it. Both cards carry this so they render the same width; giving
            // it to only one would trade one mismatch for another.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// FR-3.5/FR-3.4/FR-5.13: a network place-name lookup that is still
    /// working is deferred work, and the blurb above already names the one
    /// network exception it belongs to — this row is what keeps that work
    /// from reading as finished the moment Vision's own "Analysis complete"
    /// (in the card below this one) suggests everything about the library
    /// is done. Always built, faded at zero rather than removed — matching
    /// `AnalysisView.statRow`'s pattern, not `progressRow`'s delayed
    /// `shownWhileWaiting`, since this reports a slow, long-lived
    /// background fact rather than a transient wait worth debouncing —
    /// so it never changes this card's height (FR-8.7).
    private var placeNameLookupRow: some View {
        let pending = catchUp.placeNamesPending
        // `.monospacedDigit()`, matching every other live-updating count in
        // this card and in `AnalysisView`'s stat rows: this count changes
        // while the row sits still, and a proportional face lets the text
        // (and so the row) shift width as digits change — exactly the
        // control-resizing FR-8.7 forbids for the app's own background work.
        return Label("\(pending.counted("place name")) still being looked up", systemImage: "mappin.and.ellipse")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .opacity(pending > 0 ? 1 : 0)
            .accessibilityHidden(pending == 0)
    }

    /// The running count, in a slot that is there whether or not a pass is.
    ///
    /// Built unconditionally and faded rather than inserted, per FR-8.7: every
    /// pass is now the app's own work — nobody asks for one — so inserting
    /// these two rows when one began would push the analysis card and the
    /// whole candidate grid down the page with no act of the user's behind it.
    /// Reserving the rows for good costs a fixed strip of empty card and buys a
    /// column that never jumps. `shownWhileWaiting` supplies FR-2.4's other
    /// half — "a change small enough to be instant simply appears": a pass that
    /// beats `Thresholds.noticeableWaitDelay` finishes without ever flashing a
    /// bar nobody could have read.
    private var progressRow: some View {
        let progress = scanProgress
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.value, total: progress.total)
                // Pinned to the linear style, in both states. Left to itself a
                // `ProgressView` with no value draws as a *circular* spinner,
                // and a bar that turned into a spinner and back mid-pass would
                // resize the row this slot exists to keep still (FR-8.7).
                // Named explicitly, the indeterminate and determinate forms are
                // the same bar in the same track.
                .progressViewStyle(.linear)
            Text(progress.caption)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .shownWhileWaiting(scanner.isScanning)
    }

    /// Indeterminate until the library's size is known, determinate after —
    /// and exactly one line of caption throughout.
    ///
    /// The `nil` value is deliberate, and it is the one place this row is
    /// allowed to change what it draws. `PHAsset.fetchAssets` has to come back
    /// before there is any denominator to count against, and on a large cold
    /// library that gap outlasts `Thresholds.noticeableWaitDelay`, so the slot
    /// is on screen for it. A determinate bar sitting at zero for those
    /// seconds reads as work that has stalled, which is the opposite of the
    /// live progress FR-2.4 promises; an indeterminate bar says "working, no
    /// count yet", which is the truth. It costs nothing under FR-8.7 because
    /// `.progressViewStyle(.linear)` above keeps both forms the same size —
    /// only the fill changes, not the geometry.
    ///
    /// A one-line caption for the same reason as the fixed slot: the longest
    /// count must not wrap and grow the row. The values outside `.scanning`
    /// are only ever rendered at zero opacity, so they just have to keep the
    /// slot the size it will need.
    private var scanProgress: (value: Double?, total: Double, caption: String) {
        guard case .scanning(let examined, let total) = scanner.phase, total > 0 else {
            return (nil, 1, "Preparing…")
        }
        // FR-8.1: locale-grouped digits and "photo" agreeing with `total`
        // (the count it quantifies — "of 1 photo", not "of 1 photos").
        return (Double(examined), Double(total), "\(examined.formatted()) of \(total.formatted()) \(total.agreeing("photo")) examined")
    }

    /// What the app last found in the library.
    ///
    /// It reads `scanner.outcome`, not `scanner.phase`, and so survives the
    /// next pass: the previous summary stays put for the whole run and is
    /// swapped for the new one at the instant that one exists. FR-8.7 asks
    /// that redoing something move nothing *at all*, and clearing the summary
    /// only to refill the same space a few seconds later is the exact shape it
    /// names.
    @ViewBuilder
    private var outcome: some View {
        if let outcome = scanner.outcome {
            outcomeContent(outcome)
        }
    }

    @ViewBuilder
    private func outcomeContent(_ outcome: LibraryScanner.Outcome) -> some View {
        switch outcome {
        case .finished(let candidates, let examined, let newlyAdded, let editedQueued, let removed):
            // FR-4.13: this count and the Analysis card's "Wallpaper
            // candidates" stat below it are two different numbers over the
            // same word — this one is everything that merely qualifies by
            // size and shape, Vision hasn't looked yet; that one is what
            // survived Vision's checks and can actually compete for the
            // album. They used to share the same visible phrase
            // ("N wallpaper candidates" over "Wallpaper candidates N"),
            // distinguished only by a `.help()` tooltip — invisible to
            // keyboard, VoiceOver, and touch, so those users saw two
            // contradicting-looking numbers with no explanation at all
            // (observed live: "3 wallpaper candidates" over "Wallpaper
            // candidates 0"). "Possible" plus the sentence below now carries
            // that distinction in words everyone can read.
            Label("\(candidates.counted("possible candidate found", "possible candidates found"))", systemImage: "photo.stack")
                .font(.callout.weight(.semibold))
                .help("Photos whose size and shape qualify them for the wallpaper pipeline; Vision analysis below filters them further.")
            Text("Vision analysis narrows this to the wallpaper candidates shown below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(scanSummary(examined: examined, newlyAdded: newlyAdded, editedQueued: editedQueued, removed: removed))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            // FR-8.12: a pass that failed says so, rather than leaving the
            // last good summary to imply the app is current when it isn't.
            Label("Couldn't read the library", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("The last pass over the library stopped with the error below; Firnlight tries again the next time your library changes.")
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scanSummary(examined: Int, newlyAdded: Int, editedQueued: Int, removed: Int) -> String {
        // FR-8.1: locale-grouped digits throughout, and "photo"/"photos"
        // agreeing with `examined` — the others ("new", "edited", with no
        // noun of their own) have nothing to agree.
        var parts = ["Examined \(examined.counted("photo"))", "added \(newlyAdded.formatted()) new"]
        if editedQueued > 0 {
            parts.append("queued \(editedQueued.formatted()) edited for re-analysis")
        }
        if removed > 0 {
            parts.append("removed \(removed.formatted())")
        }
        return parts.joined(separator: ", ") + "."
    }
}

#Preview {
    ContentView()
}
