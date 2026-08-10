import SwiftUI
import SwiftData

/// FR-8.3's menu bar and the focused-value plumbing that feeds it.
///
/// The commands here act on state that already lives view-locally (the
/// grid's `selection`, the Library tab's analysis model,
/// `ExportView`'s sync model, and whichever photo currently has keyboard
/// focus). `Commands` runs outside that view hierarchy, so the bridge is
/// `FocusedValues`: each owning view publishes its state via
/// `.focusedSceneValue(\.key, value)`, and `AppCommands` reads it back with
/// `@FocusedValue`. A menu item reading a nil focused value disables itself
/// for free — including the "not authorized" case, since every publish site
/// below sits inside an `if authorization.isAuthorized` branch (or, for the
/// photo actions, inside a view that only exists once there's a photo to
/// show), so there's nothing to publish when the precondition doesn't hold.
/// A deliberate consequence: stop/resume, Sync Album, and the Library view
/// switch are enabled only while their owning tab is mounted (a `focusedSceneValue`
/// publishes only from views in the hierarchy). That errs safe — a disabled
/// item is never wrong, and the enabled state always reflects a target that
/// really can act — at the cost of the commands being tab-scoped rather than
/// app-global.
///
/// Every value published here is a reference type (a `@MainActor
/// @Observable` model, or `ModelContext`, itself a class) or a plain
/// value-type record of such references — never a closure. Closures can't
/// be compared, so a `FocusedValueKey` backed by one invalidates every
/// reader on every write (see the swiftui-specialist skill's
/// `environment.md`); by publishing the model instead and letting the
/// command call real methods on it, comparison is by identity and reads
/// stay stable.
///
/// FR-8.3 is marked *(macOS)*, so only `AppCommands` itself — the menu bar —
/// is compiled out on iPhone and iPad. The focused-value keys below stay
/// cross-platform on purpose: they are how a view says "this is the photo the
/// user is on", which is true on any platform, and keeping them unconditional
/// means the publishing views need no `#if` of their own.
///
/// FR-8.4 is the iPhone and iPad counterpart, and it is answered in the views
/// rather than here, because touch has no menu bar to hang commands off. Every
/// command FR-8.3 lists already has a visible, named, touch-reachable control
/// on those platforms: stopping and resuming a run is `AnalysisView`'s
/// button, album sync is `ExportView`'s, and the Library view switch is the
/// picker in the grid header. The three photo actions and the un-marking directions were the
/// exception — reachable only by a long press — so `ThumbnailCell` and
/// `DuelCard` grow a visible actions menu there, offering the same commands
/// by the same names this menu bar does, and `ThumbnailCell` additionally
/// grows the FR-4.14 overlay toggles for one-tap access.

// MARK: - Focused photo (FR-4.6)

/// The photo currently under keyboard/VoiceOver focus, wherever it is: a
/// grid cell, an export-preview cell (same `ThumbnailCell`), or a duel
/// card. Published by whichever of those is focused, via `.focusedValue`
/// (not `.focusedSceneValue` — focus is per-window, and a photo's focus
/// state is exactly as local as `View.focusable()` already makes it).
struct FocusedPhoto {
    let localIdentifier: String
    /// Whether this photo currently carries the "Ignore This Photo" verdict
    /// (FR-4.6) — true anywhere it is shown, not just in a particular
    /// review list. The Photo menu reads this to word its "Ignore This
    /// Photo" / "Un-ignore" item as the action's reverse (FR-8.3).
    let isIgnored: Bool
    /// Whether this photo currently carries the "Not Wallpaper Material"
    /// verdict (FR-4.6), same rationale as `isIgnored`. Read by the Photo
    /// menu to word its verdict item as "Not Wallpaper Material" / "Clear
    /// Verdict".
    let isNotWallpaperMaterial: Bool
    let modelContext: ModelContext
    /// Set only when the focused photo is a duel card: "Not Wallpaper
    /// Material" and "Ignore This Photo" spend the current pair, so the menu
    /// path must advance to a fresh one just like the context-menu path's
    /// `onAdvance` does (FR-4.7/FR-4.8). A model reference, not a closure,
    /// for the same identity-comparison reason as everything else here.
    var duelModel: DuelModel?
}

private struct FocusedPhotoKey: FocusedValueKey {
    typealias Value = FocusedPhoto
}

extension FocusedValues {
    var focusedPhoto: FocusedPhoto? {
        get { self[FocusedPhotoKey.self] }
        set { self[FocusedPhotoKey.self] = newValue }
    }
}

// MARK: - Library commands (stop / resume a run)

/// What FR-8.3's stop and resume items need: the analysis model whose run they
/// act on, and a `ModelContext` for its container. Published by `LibraryTab`
/// only while the whole library is available (FR-1.8), so both items are
/// disabled for free when there is nothing the app could be running.
///
/// There is no scan command any more, and none is missing: FR-2.7 removed the
/// control it would have driven — the app is always current, so a "Scan Again"
/// item would name an action with nothing to find.
struct LibraryCommandTarget {
    let analysisModel: AnalysisModel
    let modelContext: ModelContext

    /// The same two conditions the Library card's own control uses, so
    /// FR-8.3's two routes to one action cannot drift apart.
    var canStop: Bool { analysisModel.isRunning }

    var canResume: Bool {
        guard !analysisModel.isRunning, analysisModel.isStoppedByUser else { return false }
        guard let stats = analysisModel.stats else { return false }
        return stats.pending + stats.skipped > 0
    }
}

private struct LibraryCommandTargetKey: FocusedValueKey {
    typealias Value = LibraryCommandTarget
}

extension FocusedValues {
    var libraryCommandTarget: LibraryCommandTarget? {
        get { self[LibraryCommandTargetKey.self] }
        set { self[LibraryCommandTargetKey.self] = newValue }
    }
}

// MARK: - Grid model (Library view switch, FR-4.9)

private struct LibraryGridModelKey: FocusedValueKey {
    typealias Value = GridModel
}

extension FocusedValues {
    /// Published by `CandidateGridView` (the Library tab's grid) so the View
    /// menu's Library-view commands reflect and control the same
    /// `GridModel.selection` the in-view picker does — one source of truth,
    /// read from two places.
    var libraryGridModel: GridModel? {
        get { self[LibraryGridModelKey.self] }
        set { self[LibraryGridModelKey.self] = newValue }
    }
}

// MARK: - Export commands (album sync)

/// What "Sync Album" needs: the export model to trigger the sync and read
/// `isSyncing`/`canSync` from, and a `ModelContext` for its container.
struct ExportCommandTarget {
    let model: ExportModel
    let modelContext: ModelContext
}

private struct ExportCommandTargetKey: FocusedValueKey {
    typealias Value = ExportCommandTarget
}

extension FocusedValues {
    var exportCommandTarget: ExportCommandTarget? {
        get { self[ExportCommandTargetKey.self] }
        set { self[ExportCommandTargetKey.self] = newValue }
    }
}

// MARK: - The menu bar (macOS)

#if os(macOS)
/// Named commands for FR-8.3, attached to the `Window` scene via
/// `.commands { AppCommands() }`. Quit (⌘Q) needs no entry here — it's part
/// of the automatic app menu and nothing below replaces it.
struct AppCommands: Commands {
    @Environment(\.openURL) private var openURL
    @FocusedValue(\.focusedPhoto) private var focusedPhoto
    @FocusedValue(\.libraryCommandTarget) private var libraryCommandTarget
    @FocusedValue(\.libraryGridModel) private var gridModel
    @FocusedValue(\.exportCommandTarget) private var exportCommandTarget

    var body: some Commands {
        CommandMenu("Photo") {
            Button("Open in Photos") {
                guard let focusedPhoto else { return }
                CandidateActions.openInPhotos(focusedPhoto.localIdentifier, using: openURL)
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(focusedPhoto == nil)

            Divider()

            // FR-8.3: both verdict items are always listed — the old code
            // hid "Not Wallpaper Material" entirely for an ignored photo,
            // which left the menu silently missing a command FR-8.3 names —
            // and each reads as its reverse once the photo already carries
            // that verdict (FR-4.6). The verdict item is *disabled* rather
            // than hidden on an ignored photo, for the reason
            // `ThumbnailCell.verdictToggles` documents: an ignored photo has
            // no ranker entry, so the verdict would be silently dropped.
            //
            // Only the *marking* direction spends the duel pair: clearing a
            // verdict mid-duel doesn't remove the photo from the pool, so
            // nothing needs to advance past it — the un-marking branches
            // below deliberately don't call `duelModel?.skip()`.
            Button(focusedPhoto?.isNotWallpaperMaterial == true ? "Clear Verdict" : "Not Wallpaper Material") {
                guard let focusedPhoto else { return }
                CandidateActions.setNotWallpaperMaterial(
                    focusedPhoto.localIdentifier,
                    !focusedPhoto.isNotWallpaperMaterial,
                    in: focusedPhoto.modelContext
                )
                if !focusedPhoto.isNotWallpaperMaterial {
                    // Mid-duel, the acted-on pair is spent (FR-4.7).
                    focusedPhoto.duelModel?.skip()
                }
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(focusedPhoto == nil || focusedPhoto?.isIgnored == true)

            Button(focusedPhoto?.isIgnored == true ? "Un-ignore" : "Ignore This Photo") {
                guard let focusedPhoto else { return }
                CandidateActions.setIgnored(focusedPhoto.localIdentifier, !focusedPhoto.isIgnored, in: focusedPhoto.modelContext)
                if !focusedPhoto.isIgnored {
                    // Mid-duel, advance immediately (FR-4.8) rather than
                    // waiting for the RankingClock reload to notice the
                    // excluded photo.
                    focusedPhoto.duelModel?.skip()
                }
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(focusedPhoto == nil)
        }

        // Placed in the standard View menu, alongside the toolbar-visibility
        // toggles SwiftUI already puts there — the Library view switch is
        // exactly that kind of view-mode command (FR-4.9). Three `Button`s
        // with checkmarks rather than a `Picker`: a `Picker` embedded in
        // `Commands` renders as a submenu whose items can't each carry their
        // own `.keyboardShortcut`, and ⌘1/⌘2/⌘3 (the standard macOS
        // view-mode idiom, as in Finder's icon/list/column switch) needs
        // per-item shortcuts.
        CommandGroup(after: .toolbar) {
            ForEach(LibraryView.allCases) { view in
                Button {
                    gridModel?.selection = view
                } label: {
                    if gridModel?.selection == view {
                        Label(view.title, systemImage: "checkmark")
                    } else {
                        Text(view.title)
                    }
                }
                .keyboardShortcut(shortcutKey(for: view), modifiers: [.command])
                .disabled(gridModel == nil)
            }
        }

        CommandMenu("Library") {
            // FR-8.3's stop and resume (FR-3.5), as two items rather than one
            // that renames itself: a menu item whose title changes as the app's
            // own work starts and settles resizes while nobody is acting, which
            // FR-8.7 does not allow. Each is disabled when it has nothing to
            // act on, which is the state the requirement asks for anyway.
            Button("Stop Analysis") {
                libraryCommandTarget?.analysisModel.stop()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(libraryCommandTarget?.canStop != true)

            Button("Resume Analysis") {
                guard let libraryCommandTarget else { return }
                libraryCommandTarget.analysisModel.start(container: libraryCommandTarget.modelContext.container)
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(libraryCommandTarget?.canResume != true)

            Divider()

            // Named for the command, not for the state of the work: retitling
            // it "Syncing…" mid-sync resized a menu item while the app worked,
            // which FR-8.7 forbids. `canSync` already goes false for the
            // duration, so the item greys out — same width, same place — and
            // the Export tab's own spinner reports the wait.
            Button("Sync Album") {
                guard let exportCommandTarget else { return }
                exportCommandTarget.model.sync(container: exportCommandTarget.modelContext.container)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(exportCommandTarget?.model.canSync != true)
        }
    }

    /// ⌘1/⌘2/⌘3 for the three Library views, in `LibraryView.allCases` order.
    /// The TabView in ContentView.swift doesn't claim ⌘1–⌘3 itself, so these
    /// are free for the Library tab's own view switch.
    private func shortcutKey(for view: LibraryView) -> KeyEquivalent {
        switch view {
        case .library: "1"
        case .notWallpaperMaterial: "2"
        case .ignored: "3"
        }
    }
}
#endif
