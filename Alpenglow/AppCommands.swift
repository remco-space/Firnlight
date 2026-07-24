import SwiftUI
import SwiftData

/// FR-8.3's menu bar and the focused-value plumbing that feeds it.
///
/// The commands here act on state that already lives view-locally (the
/// grid's `showingIgnored`, `LibraryTab`'s `scanner`/`analysisModel`,
/// `ExportView`'s sync model, and whichever photo currently has keyboard
/// focus). `Commands` runs outside that view hierarchy, so the bridge is
/// `FocusedValues`: each owning view publishes its state via
/// `.focusedSceneValue(\.key, value)`, and `AppCommands` reads it back with
/// `@FocusedValue`. A menu item reading a nil focused value disables itself
/// for free — including the "not authorized" case, since every publish site
/// below sits inside an `if authorization.isAuthorized` branch (or, for the
/// photo actions, inside a view that only exists once there's a photo to
/// show), so there's nothing to publish when the precondition doesn't hold.
///
/// Every value published here is a reference type (a `@MainActor
/// @Observable` model, or `ModelContext`, itself a class) or a plain
/// value-type record of such references — never a closure. Closures can't
/// be compared, so a `FocusedValueKey` backed by one invalidates every
/// reader on every write (see the swiftui-specialist skill's
/// `environment.md`); by publishing the model instead and letting the
/// command call real methods on it, comparison is by identity and reads
/// stay stable.

// MARK: - Focused photo (FR-4.6)

/// The photo currently under keyboard/VoiceOver focus, wherever it is: a
/// grid cell, an export-preview cell (same `ThumbnailCell`), or a duel
/// card. Published by whichever of those is focused, via `.focusedValue`
/// (not `.focusedSceneValue` — focus is per-window, and a photo's focus
/// state is exactly as local as `View.focusable()` already makes it).
struct FocusedPhoto {
    let localIdentifier: String
    /// True only for a grid cell shown in the Library tab's "Show Ignored"
    /// filter — the Photo menu offers "Un-ignore" instead of the other two
    /// actions there, mirroring `ThumbnailCell.menu`.
    let isIgnored: Bool
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

// MARK: - Library commands (scan / re-scan)

/// What "Scan Library" / "Scan Again" needs: the scanner to drive, the
/// analysis model whose run also has to be idle (scanning while analysis
/// walks the same store would race), and a `ModelContext` to scan into.
/// Published by `LibraryTab` only while Photos access is authorized.
struct LibraryCommandTarget {
    let scanner: LibraryScanner
    let analysisModel: AnalysisModel
    let modelContext: ModelContext

    var canScan: Bool { !scanner.isScanning && !analysisModel.isRunning }
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

// MARK: - Grid model (Show Ignored, FR-4.9)

private struct LibraryGridModelKey: FocusedValueKey {
    typealias Value = GridModel
}

extension FocusedValues {
    /// Published by `CandidateGridView` (the Library tab's grid) so the View
    /// menu's "Show Ignored" toggle reflects and controls the same
    /// `GridModel.showingIgnored` the in-view switch does — one source of
    /// truth, read from two places.
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

// MARK: - The menu bar

/// Named commands for FR-8.3, attached to the `WindowGroup` via
/// `.commands { AppCommands() }`. Quit (⌘Q) needs no entry here — it's part
/// of the automatic app menu and nothing below replaces it.
struct AppCommands: Commands {
    @FocusedValue(\.focusedPhoto) private var focusedPhoto
    @FocusedValue(\.libraryCommandTarget) private var libraryCommandTarget
    @FocusedValue(\.libraryGridModel) private var gridModel
    @FocusedValue(\.exportCommandTarget) private var exportCommandTarget

    var body: some Commands {
        CommandMenu("Photo") {
            Button("Open in Photos") {
                guard let focusedPhoto else { return }
                CandidateActions.openInPhotos(focusedPhoto.localIdentifier)
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(focusedPhoto == nil)

            Divider()

            if focusedPhoto?.isIgnored == true {
                Button("Un-ignore") {
                    guard let focusedPhoto else { return }
                    CandidateActions.unignore(focusedPhoto.localIdentifier, in: focusedPhoto.modelContext)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            } else {
                Button("Not Wallpaper Material") {
                    guard let focusedPhoto else { return }
                    CandidateActions.markNotWallpaperMaterial(focusedPhoto.localIdentifier, in: focusedPhoto.modelContext)
                    // Mid-duel, the acted-on pair is spent (FR-4.7).
                    focusedPhoto.duelModel?.skip()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(focusedPhoto == nil)

                Button("Ignore This Photo") {
                    guard let focusedPhoto else { return }
                    CandidateActions.ignore(focusedPhoto.localIdentifier, in: focusedPhoto.modelContext)
                    // Mid-duel, advance immediately (FR-4.8) rather than
                    // waiting for the RankingClock reload to notice the
                    // excluded photo.
                    focusedPhoto.duelModel?.skip()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(focusedPhoto == nil)
            }
        }

        // Placed in the standard View menu, alongside the toolbar-visibility
        // toggles SwiftUI already puts there — "Show Ignored" is exactly
        // that kind of filter toggle (FR-4.9).
        CommandGroup(after: .toolbar) {
            Toggle("Show Ignored", isOn: Binding(
                get: { gridModel?.showingIgnored ?? false },
                set: { gridModel?.showingIgnored = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(gridModel == nil)
        }

        CommandMenu("Library") {
            Button(scanTitle) {
                guard let libraryCommandTarget else { return }
                Task { await libraryCommandTarget.scanner.scan(into: libraryCommandTarget.modelContext) }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(libraryCommandTarget == nil || libraryCommandTarget?.canScan == false)

            Divider()

            Button(exportCommandTarget?.model.isSyncing == true ? "Syncing…" : "Sync Album") {
                guard let exportCommandTarget else { return }
                exportCommandTarget.model.sync(container: exportCommandTarget.modelContext.container)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(exportCommandTarget?.model.canSync != true)
        }
    }

    private var scanTitle: String {
        libraryCommandTarget?.scanner.phase == .idle ? "Scan Library" : "Scan Again"
    }
}
