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

struct ContentView: View {
    @State private var authorization = PhotoLibraryAuthorization()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// The scan → analyze pipeline, owned here rather than by the Library tab
    /// that displays it. FR-2.7's startup re-sync drives these, and it has to
    /// run whichever tab the user is on — see the `.task` below.
    @State private var scanner = LibraryScanner()
    @State private var analysisModel = AnalysisModel()

    // FR-8.1: persist which tab the user was on. `@AppStorage`, not the more
    // idiomatic `@SceneStorage`, because `@SceneStorage` restores through
    // AppKit's window-restoration machinery — it needs a window to still
    // exist, or be reconstructable, across launches. Alpenglow is a
    // single-window app that quits when its window closes (FR-1.7), so there
    // is no surviving window state for `@SceneStorage` to hang its restore
    // off; in practice it doesn't come back on the next launch. `@AppStorage`
    // is a flat UserDefaults value with no dependency on window restoration,
    // so it reliably survives quit → relaunch.
    @AppStorage("selectedTab") private var selectedTab = AppTab.library

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "photo.on.rectangle.angled", value: AppTab.library) {
                LibraryTab(authorization: authorization, scanner: scanner, analysisModel: analysisModel)
            }
            Tab("Duel", systemImage: "rectangle.split.2x1", value: AppTab.duel) {
                DuelView()
            }
            Tab("Export", systemImage: "square.and.arrow.up", value: AppTab.export) {
                ExportView()
            }
        }
        // No minimum size here: on the Mac the window owns that (see
        // AlpenglowApp), and on iPhone the screen is narrower than any floor
        // worth setting.
        .onChange(of: scenePhase) { _, newPhase in
            // Pick up grants made in System Settings while we were in the background.
            if newPhase == .active {
                authorization.refresh()
            }
        }
        // FR-2.7: with access already granted, launching re-syncs on its own —
        // scan, then analyze to completion, exactly as clicking the buttons
        // would.
        //
        // Attached to the TabView, not to the Library tab that shows the
        // progress, because `TabView` only builds the *selected* tab: while
        // this lived in `LibraryTab.task`, FR-8.1 restoring the user to Export
        // or Duel meant the tab never mounted and the re-sync silently never
        // ran. FR-2.7 is unconditional, so its trigger has to hang off
        // something that exists on every launch regardless of tab.
        //
        // `.task(id:)` on the authorization state rather than a plain `.task`
        // and a "did this already" flag: the re-sync must also start the
        // moment the user grants access without relaunching (FR-1.3), which is
        // exactly when this id flips. Re-running after a revoke → re-grant is
        // correct too, not a double-run to guard against — and a redundant
        // trigger is a no-op anyway, since `scan` returns early while a scan is
        // in flight and `start` hands back the already-running task.
        //
        // Nothing about *where* the work runs changes: the scan yields
        // cooperatively and analysis runs in its own actor off the main thread,
        // so the rest of the app stays live behind their progress (FR-8.2), and
        // switching to Library mid-run picks up the same observable models
        // already counting up (FR-2.4, FR-4.11).
        .task(id: authorization.isAuthorized) {
            guard authorization.isAuthorized else { return }
            // Deliberately no album work here. Recovering an interrupted sync
            // (FR-6.8) is offered in the Export tab instead of done on launch,
            // because these devices share one album and FR-6.10 forbids
            // changing it unattended — see WallpaperAlbumSync.restoreInterruptedSync.
            await scanner.scan(into: modelContext)
            // start() rescores and bumps RankingClock when it finishes.
            await analysisModel.start(container: modelContext.container).value
        }
    }
}

/// Library tab: Photos authorization flow, then the scan → analyze pipeline.
private struct LibraryTab: View {
    let authorization: PhotoLibraryAuthorization
    /// Owned by `ContentView`, because FR-2.7's startup re-sync drives them
    /// from outside any tab. This tab renders their progress and offers the
    /// manual scan / analyze / retry controls onto the same two models, so a
    /// run the user starts here and one the launch started are the same run.
    let scanner: LibraryScanner
    let analysisModel: AnalysisModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    // FR-8.1: restore roughly where the user had scrolled to. Seeded from the
    // persisted vertical offset at view-creation time, so SwiftUI applies it
    // as the ScrollView's *initial* position once content lays out — there's
    // no separate "wait for the grid, then scroll" step to get right.
    //
    // Fidelity trade-off, deliberate: this restores a raw pixel offset, not a
    // specific photo's position. The Library tab's content is the scan/
    // analysis cards followed by the ranked grid, and the grid re-orders
    // itself between launches as duels retrain the ranking (FR-4.5) — so a
    // pixel-perfect "same photo under the cursor" restore is impossible
    // anyway (the content at that offset isn't guaranteed to be the same). An
    // approximate return to the same scrolled region is what FR-8.1 asks for
    // and what this delivers; a per-item anchor would be more precise for the
    // grid specifically but couldn't survive the cards above it changing
    // height (e.g. a scan summary appearing) between launches either.
    @State private var scrollPosition = ScrollPosition(
        y: CGFloat(UserDefaults.standard.double(forKey: "libraryScrollOffsetY"))
    )
    /// Tracks the live offset so it can be written out once, at a natural
    /// checkpoint, rather than on every scroll-geometry callback. Seeded from
    /// the same persisted value as `scrollPosition`, so a quit before the
    /// first scroll-geometry callback re-persists the restored offset instead
    /// of clobbering it with 0.
    @State private var currentScrollOffsetY = CGFloat(UserDefaults.standard.double(forKey: "libraryScrollOffsetY"))

    var body: some View {
        if authorization.isAuthorized {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 20) {
                        if authorization.status == .limited {
                            limitedAccessBanner
                        }
                        ScanView(scanner: scanner)
                        AnalysisView(model: analysisModel, scanToken: scanCompletionToken)
                    }
                    .frame(maxWidth: 560)

                    CandidateGridView()
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
            // FR-8.3: lets the menu bar's "Scan Library"/"Scan Again" trigger
            // the same scan this tab's own button does. Published only in
            // this authorized branch, so the command is disabled for free
            // whenever Photos access isn't granted — see AppCommands.swift.
            .focusedSceneValue(\.libraryCommandTarget, LibraryCommandTarget(
                scanner: scanner,
                analysisModel: analysisModel,
                modelContext: modelContext
            ))
        } else {
            authorizationPrompt
        }
    }

    /// What limited access means, which differs by platform.
    ///
    /// On the Mac it is a narrowing: the app sees fewer photos, and everything
    /// else still works, so FR-1.2's job is to offer a shortcut to change the
    /// selection. There is no in-app route — PhotoKit's limited-library picker
    /// (`presentLimitedLibraryPickerFromViewController:`) is
    /// `API_UNAVAILABLE(macos)` with no AppKit counterpart as of macOS 27 beta
    /// 4 — so the button opens the Privacy pane with a label honest about the
    /// extra step needed there (System Settings → Privacy & Security → Photos
    /// → Edit Selected Photos) rather than implying a one-click reselect.
    ///
    /// On iPhone and iPad it is disqualifying (FR-1.8). Under `.limited`
    /// PhotoKit cannot create or fetch user albums at all, and it fails
    /// *silently* — `performChanges` reports success and the following fetch
    /// returns nothing — so a banner about "which photos are available" would
    /// let the app look like it was working while the album it exists to
    /// maintain could never be written. The banner therefore leads with that,
    /// and the button offers the only upgrade path that exists: the app's own
    /// Settings page. There is no API to re-prompt for full access, and the
    /// limited-library picker only edits the selection (see
    /// `PhotoLibraryAuthorization.settingsURL`).
    private var limitedAccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true) // decorative — the text beside it already carries the meaning (FR-4.13)
                .help(limitedAccessHelp)
            Text(limitedAccessMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            #if os(macOS)
            Button("Change Selection in Settings…") { openPrivacySettings() }
            #else
            Button("Allow Access to All Photos…") { openPrivacySettings() }
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var limitedAccessMessage: String {
        #if os(macOS)
        "Only your selected photos are available to Alpenglow."
        #else
        "Alpenglow can't maintain the wallpaper album with limited photo access. Allow access to all photos to use it."
        #endif
    }

    private var limitedAccessHelp: String {
        #if os(macOS)
        "Photos access is limited — Alpenglow only sees the photos you selected, so wallpapers can only come from that selection."
        #else
        "Photos only lets apps create and update albums with access to the whole library, so the wallpaper album can't be maintained with limited access."
        #endif
    }

    /// Non-nil once a scan has finished; value changes when results change.
    private var scanCompletionToken: Int? {
        if case .finished(let candidates, _, let newlyAdded, let editedQueued, let removed, let hidden) = scanner.phase {
            candidates &+ newlyAdded &+ editedQueued &+ removed &+ hidden
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
                .help("Alpenglow can't read your Photos library yet — grant access to start finding wallpapers.")

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
            case .denied:
                // `.restricted` (parental controls/MDM) has no button here:
                // Privacy Settings can't grant it — only the managing admin
                // can — so offering the same shortcut as `.denied` would be a
                // dead end. `statusMessage` above already explains why.
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
            "Alpenglow needs to read your photo library to find wallpaper-worthy nature photos. Everything stays on your device."
        case .authorized:
            "Access granted."
        case .limited:
            "Limited access granted. Alpenglow can only see the photos you selected."
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
    /// per-platform destination lives on `PhotoLibraryAuthorization` because
    /// the Export tab needs the same one for FR-1.8; opening it is the same
    /// `openURL` on both platforms.
    private func openPrivacySettings() {
        guard let url = PhotoLibraryAuthorization.settingsURL else { return }
        openURL(url)
    }
}

/// Metadata scan card: run state, progress, and result summary.
private struct ScanView: View {
    @Environment(\.modelContext) private var modelContext
    let scanner: LibraryScanner

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Library Scan")
                    .font(.headline)

                switch scanner.phase {
                case .idle:
                    Text("Finds high-resolution landscape photos worth considering as wallpapers. Metadata only — fast, and nothing leaves your device.")
                        .foregroundStyle(.secondary)
                    scanButton(title: "Scan Library")

                case .scanning(let examined, let total):
                    ProgressView(value: total > 0 ? Double(examined) : nil, total: Double(max(total, 1)))
                    Text(total > 0 ? "\(examined) of \(total) photos examined" : "Preparing…")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                case .finished(let candidates, let examined, let newlyAdded, let editedQueued, let removed, let hidden):
                    Label("\(candidates) wallpaper candidates", systemImage: "photo.stack")
                        .font(.callout.weight(.semibold))
                        .help("Photos whose size and shape qualify them for the wallpaper pipeline; Vision analysis filters them further.")
                    Text(scanSummary(examined: examined, newlyAdded: newlyAdded, editedQueued: editedQueued, removed: removed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // FR-2.4: don't let the headline count quietly include
                    // photos this scan couldn't see. Only ever appears under
                    // limited access, where their records are kept on purpose
                    // rather than deleted.
                    if hidden > 0 {
                        Text("\(hidden) more can't be seen with limited photo access — their analysis is kept and returns when you allow access to all photos.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    scanButton(title: "Scan Again")

                case .failed(let message):
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("The library scan stopped with the error below; scanning again is safe.")
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    scanButton(title: "Try Again")
                }
            }
            .padding(8)
            // Matches `AnalysisView`'s card — see the note there for why the
            // stretch has to be applied inside the `GroupBox` rather than to
            // it. Both cards carry this so they render the same width; giving
            // it to only one would trade one mismatch for another.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scanSummary(examined: Int, newlyAdded: Int, editedQueued: Int, removed: Int) -> String {
        var parts = ["Examined \(examined) photos", "added \(newlyAdded) new"]
        if editedQueued > 0 {
            parts.append("queued \(editedQueued) edited for re-analysis")
        }
        if removed > 0 {
            parts.append("removed \(removed)")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// Never prominent, in any scan phase. FR-8.5 allows at most one prominent
    /// action per screen and the Library tab shows this card and the analysis
    /// card together, so exactly one of the two has to own that style — and it
    /// is the analysis card: FR-3.5 names the tab's next action in that card's
    /// vocabulary throughout ("Analyze N Photos", "Resume", "Retry N iCloud
    /// Photos", "Analysis complete"), never in this one's. Scanning is not the
    /// action the user is being led towards; under FR-2.7 it starts on its own
    /// at launch, and this button exists to repeat it on demand.
    ///
    /// Deciding it here, statically, rather than from the pipeline's state is
    /// the point. An earlier version made this prominent while the scanner was
    /// `.idle`, reasoning that the analysis card could not yet be offering
    /// anything — true when written, and untrue as soon as an `await` landed
    /// ahead of the scan in `ContentView`'s startup task: through a restore of
    /// an interrupted sync (FR-6.8) the scanner sits `.idle` for as long as
    /// that Photos work takes, while `AnalysisView`'s own `.task` loads stats
    /// and renders a prominent "Analyze N Photos" beside it. A rule that holds
    /// only while the call graph above it stays a particular shape is not a
    /// rule; this one holds unconditionally.
    private func scanButton(title: String) -> some View {
        Button(title) {
            Task { await scanner.scan(into: modelContext) }
        }
    }
}

#Preview {
    ContentView()
}
