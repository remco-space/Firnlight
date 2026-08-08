import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// App entry point.
///
/// Platform constraints baked into the whole design: macOS 27+ and iOS 27+
/// (iPhone and iPad), Swift 6 strict concurrency, SwiftUI + PhotoKit + Vision
/// (modern async struct API) + SwiftData + Accelerate. No third-party
/// dependencies and no telemetry; all processing currently runs on-device with
/// no network calls. (FR-1.5 permits Apple's Private Cloud Compute for
/// higher-level foundation-model work, retaining no data; the app uses none
/// today.) Every stage that touches the store runs as a plain actor owning its
/// own ModelContext, off the main thread (see FeatureStore for why @ModelActor
/// can't deliver that); values crossing actor boundaries are nonisolated
/// Sendable structs.
///
/// Almost nothing below the scene knows which platform it is running on — the
/// pipeline is PhotoKit and Vision, which are the same on both, and the UI is
/// plain SwiftUI that each system renders its own way. What does differ is the
/// window lifecycle, and the brief says so explicitly: FR-1.6 (one instance)
/// and FR-1.7 (closing the window quits) are marked *(macOS)*, because a
/// hand-off between launches and a quit-on-close are macOS ideas — iOS owns
/// app lifetime itself and has no second instance to hand off to and no window
/// to close.
@main
struct AlpenglowApp: App {
    /// The two-store container, built once and shared by both scenes.
    ///
    /// Fatal rather than a graceful fallback: without a store there is no
    /// library, no ranking and no album, so there is no degraded mode to fall
    /// back to — an in-memory container would silently pretend the user's
    /// whole analyzed library didn't exist, which is worse than not launching.
    /// The one genuinely recoverable failure, the legacy judgment migration,
    /// is handled inside `JudgmentStore` and never throws out here.
    private let modelContainer: ModelContainer = {
        do {
            return try JudgmentStore.makeContainer()
        } catch {
            fatalError("Could not open the Alpenglow store: \(error)")
        }
    }()

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.deferToExistingInstance()
        // A WindowGroup-style multi-window app gets automatic window tabbing
        // (View > Show Tab Bar, tabs merging ⌘N windows) from AppKit. Two
        // "Alpenglow" tabs of the same single pipeline are a contradiction of
        // FR-1.6/FR-1.7's single-window design, so opt out; this also removes
        // the system's Show/New Tab menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        // `Window`, not `WindowGroup`: this is a single-window utility
        // (FR-1.6/FR-1.7) — a unique-window scene means no File > New Window
        // (⌘N), and reopening the app just brings the one window forward.
        // `Window` is macOS/visionOS-only, which is fitting: the requirement
        // it implements is macOS-only too.
        Window("Alpenglow", id: "main") {
            // Window sizing belongs to the window, not to ContentView — on
            // iPhone the system decides the size and a 720 pt floor would be
            // wider than the screen.
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .modelContainer(modelContainer)
        // FR-8.3: the standard macOS menu bar's named commands (Photo
        // actions, the Library view switch, scan, sync). Quit (⌘Q) needs
        // nothing here —
        // it's already part of the automatic app menu. See AppCommands.swift
        // for the focusedValue plumbing that connects these menu items back
        // to view-local state. FR-8.3 is macOS-only and so is this; the touch
        // equivalent is FR-8.4.
        .commands {
            AppCommands()
            // FR-8.8: replaces the stock "About Alpenglow" item so the
            // standard panel opens with the app's one-sentence description
            // in it. See About.swift.
            AboutCommand()
        }
        #else
        // iPhone and iPad: `WindowGroup` is the only scene the system offers
        // for an app's main interface, and the single-window question FR-1.6
        // and FR-1.7 answer on the Mac doesn't arise — iOS already runs one
        // instance and never asks the user to close a window.
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
        #endif
    }

    #if os(macOS)
    /// LaunchServices happily starts a second instance when the app is launched
    /// from a different build location (e.g. Xcode + Finder). Two instances
    /// would race on the SwiftData store, so hand off to the one already running.
    private static func deferToExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let existing = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard let existing else { return }
        // Cooperative activation: this (launching) instance yields to the existing one.
        existing.activate(from: .current, options: [.activateAllWindows])
        exit(0)
    }
    #endif
}

#if os(macOS)
/// Quit when the window closes (FR-1.7). Alpenglow is a single-window utility
/// with no menu-bar presence or background duty — its pipeline work is driven
/// entirely by the visible UI — so an invisible lingering process would only
/// confuse ("why is it still in the Dock?") and hold Photos/SwiftData
/// resources for nothing. The delegate method is the sanctioned AppKit switch
/// for this; SwiftUI has no Scene-level equivalent, and it can't interfere
/// with `deferToExistingInstance` because a second instance exits before the
/// app (and this delegate) ever finishes launching.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Don't let the quit-on-close above tear the process down mid-album-sync:
    /// WallpaperAlbumSync rebuilds the Photos album in two transactions, and
    /// dying between them skips the rollback and strands the album (and the
    /// user's live wallpaper rotation) empty — breaking FR-6.8. While that
    /// critical section is active we defer termination and complete it once
    /// the gate reports idle (sync finished or rolled back). The reply hops
    /// through a main-actor Task because `whenIdle` may fire synchronously
    /// right here (sync ended between the two calls) — before this method has
    /// returned `.terminateLater`, which must precede the reply.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AlbumSyncGate.shared.isActive else { return .terminateNow }
        AlbumSyncGate.shared.whenIdle {
            Task { @MainActor in
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
#endif
