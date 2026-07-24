import SwiftUI
import SwiftData
import AppKit

/// App entry point.
///
/// Platform constraints baked into the whole design: macOS 27+, Apple Silicon,
/// Swift 6 strict concurrency, SwiftUI + PhotoKit + Vision (modern async struct
/// API) + SwiftData + Accelerate. No third-party dependencies and no
/// telemetry; all processing currently runs on-device with no network calls.
/// (FR-1.5 permits Apple's Private Cloud Compute for higher-level
/// foundation-model work, retaining no data; the app uses none today.) Every
/// stage that touches the store runs as a plain actor owning its own
/// ModelContext, off the main thread (see FeatureStore for why @ModelActor
/// can't deliver that); values crossing actor boundaries are nonisolated
/// Sendable structs.
@main
struct AlpenglowApp: App {
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

    var body: some Scene {
        // `Window`, not `WindowGroup`: this is a single-window utility
        // (FR-1.6/FR-1.7) — a unique-window scene means no File > New Window
        // (⌘N), and reopening the app just brings the one window forward.
        Window("Alpenglow", id: "main") {
            ContentView()
        }
        .modelContainer(for: [PhotoRecord.self, ChoiceRecord.self, VerdictRecord.self])
        // FR-8.3: the standard macOS menu bar's named commands (Photo
        // actions, Show Ignored, scan, sync). Quit (⌘Q) needs nothing here —
        // it's already part of the automatic app menu. See AppCommands.swift
        // for the focusedValue plumbing that connects these menu items back
        // to view-local state.
        .commands { AppCommands() }
    }

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
}

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
