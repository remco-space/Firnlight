import SwiftUI
import SwiftData
import AppKit

/// App entry point.
///
/// Platform constraints baked into the whole design: macOS 27+, Apple Silicon,
/// Swift 6 strict concurrency, SwiftUI + PhotoKit + Vision (modern async struct
/// API) + SwiftData + Accelerate. No third-party dependencies, no network
/// calls, no telemetry — everything runs on-device (the product's privacy
/// promise; see REQUIREMENTS.md). Every stage that touches the store runs as a
/// @ModelActor actor off the main thread; values crossing actor boundaries are
/// nonisolated Sendable structs.
@main
struct AlpenglowApp: App {
    init() {
        Self.deferToExistingInstance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [PhotoRecord.self, ChoiceRecord.self, VerdictRecord.self])
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
