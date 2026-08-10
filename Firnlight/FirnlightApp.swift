import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// App entry point.
///
/// Platform constraints baked into the whole design: macOS 26+ and iOS 26+
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
struct FirnlightApp: App {
    /// The two-store container, built once and shared by every scene — or the
    /// reason it could not be built (FR-7.3).
    ///
    /// A `Result` rather than a `fatalError`, and rather than a silent
    /// fallback, because both of those break a promise the brief now makes.
    /// Crashing is "refusing to open"; an in-memory container is "starting
    /// empty", and it would present a user whose every duel and analysis is
    /// still safely on disk with the same blank grid a fresh install shows —
    /// the exact ambiguity FR-8.12 rules out. The remaining option is the one
    /// FR-7.3 asks for: open, say what happened, and touch nothing. Nothing
    /// below this point deletes, moves or rewrites the store on a failed open,
    /// so the data an older or newer version wrote is still there for the
    /// version that can read it.
    ///
    /// The one genuinely recoverable failure, the legacy judgment migration,
    /// is handled inside `JudgmentStore` and never reaches here.
    private let store: Result<ModelContainer, Error> = Result { try JudgmentStore.makeContainer() }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.deferToExistingInstance()
        // A WindowGroup-style multi-window app gets automatic window tabbing
        // (View > Show Tab Bar, tabs merging ⌘N windows) from AppKit. Two
        // "Firnlight" tabs of the same single pipeline are a contradiction of
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
        Window("Firnlight", id: "main") {
            // Window sizing belongs to the window, not to ContentView — on
            // iPhone the system decides the size and a 720 pt floor would be
            // wider than the screen.
            //
            // The container is attached here, inside the scene's content,
            // rather than to the scene: it exists only on the success branch,
            // and a scene-level modifier would have nothing to take on the
            // other one (FR-7.3).
            rootView
                .frame(minWidth: 720, minHeight: 480)
        }
        // FR-8.3: the standard macOS menu bar's named commands (Photo
        // actions, the Library view switch, stop/resume, sync). Quit (⌘Q)
        // needs nothing here —
        // it's already part of the automatic app menu. See AppCommands.swift
        // for the focusedValue plumbing that connects these menu items back
        // to view-local state. FR-8.3 is macOS-only and so is this; the touch
        // equivalent is FR-8.4.
        .commands {
            AppCommands()
            // FR-8.8: replaces the stock "About Firnlight" item so the
            // standard panel opens with the app's one-sentence description
            // in it. See About.swift.
            AboutCommand()
        }

        // The Mac's own place for settings, behind the standard ⌘, item the
        // system adds for this scene. On iPhone and iPad the same view is a
        // sheet from the Export tab instead — see `SettingsView` for why it
        // cannot be a `Settings.bundle`.
        Settings {
            switch store {
            case .success(let container):
                SettingsView()
                    .modelContainer(container)
            case .failure(let error):
                // Copying judgments out and starting a taste over both need
                // the store the app could not open, so this window says the
                // same thing the main one does rather than offering controls
                // that could only fail (FR-8.12).
                StoreUnavailableView(error: error)
            }
        }
        #else
        // iPhone and iPad: `WindowGroup` is the only scene the system offers
        // for an app's main interface, and the single-window question FR-1.6
        // and FR-1.7 answer on the Mac doesn't arise — iOS already runs one
        // instance and never asks the user to close a window.
        WindowGroup {
            rootView
        }
        #endif
    }

    /// The app's content, or the reason there isn't any (FR-7.3, FR-8.12).
    @ViewBuilder
    private var rootView: some View {
        switch store {
        case .success(let container):
            ContentView()
                .modelContainer(container)
        case .failure(let error):
            StoreUnavailableView(error: error)
        }
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

/// FR-7.3: the app opened, its data did not, and nothing was touched.
///
/// This is the whole of "says so and leaves it intact". The commonest way to
/// get here is an update in either direction — a newer Firnlight whose schema
/// an older one cannot read, or the reverse after someone reinstalls an older
/// release — and in both cases the user's duels, verdicts and analysis are
/// sitting unharmed in a file this build cannot open. What must never happen
/// is the app quietly starting over, because a fresh-looking app is
/// indistinguishable from a lost one (FR-8.12).
///
/// It offers no repair button on purpose. There is exactly one safe action —
/// run a version that can read the store — and the only ones the app could
/// offer (delete it, rewrite it) are the very things the requirement forbids.
struct StoreUnavailableView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
                .accessibilityHidden(true) // decorative — the text below carries the meaning (FR-4.13)

            Text("Firnlight Can’t Open Your Data")
                .font(.title2.bold())

            Text("Everything you’ve decided is still on this device, exactly as it was — nothing has been changed or deleted. This version of Firnlight just can’t read it, which usually means it was written by a different version.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            Text("Installing the newest version of Firnlight — \(AppIdentity.name) \(AppIdentity.version) is running now — is the way back in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
/// Quit when the window closes (FR-1.7). Firnlight is a single-window utility
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
