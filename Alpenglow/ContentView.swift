import SwiftUI
import SwiftData
import Photos

/// Which of the three tabs is selected (FR-8.1: restore the active tab across
/// launches). A stable string raw value, not an `Int` index, so a future
/// reordering of the tabs can't silently jump the user to the wrong one.
private enum AppTab: String {
    case library, duel, export
}

struct ContentView: View {
    @State private var authorization = PhotoLibraryAuthorization()
    @Environment(\.scenePhase) private var scenePhase

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
                LibraryTab(authorization: authorization)
            }
            Tab("Duel", systemImage: "rectangle.split.2x1", value: AppTab.duel) {
                DuelView()
            }
            Tab("Export", systemImage: "square.and.arrow.up", value: AppTab.export) {
                ExportView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: scenePhase) { _, newPhase in
            // Pick up grants made in System Settings while we were in the background.
            if newPhase == .active {
                authorization.refresh()
            }
        }
    }
}

/// Library tab: Photos authorization flow, then the scan → analyze pipeline.
private struct LibraryTab: View {
    let authorization: PhotoLibraryAuthorization
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanner = LibraryScanner()
    @State private var analysisModel = AnalysisModel()

    /// Guards the once-per-session startup auto-resync.
    @State private var didAutoResync = false

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
    /// checkpoint, rather than on every scroll-geometry callback.
    @State private var currentScrollOffsetY: CGFloat = 0

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
            // Persist at the checkpoint that already exists for FR-1.3 (the
            // scenePhase watcher below), rather than on every scroll frame:
            // leaving .active — backgrounding or, for this quit-on-close app
            // (FR-1.7), quitting — is exactly when "where the user left off"
            // needs to be durable, and it's a tiny fraction of the writes a
            // per-frame save would cost.
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
            // Auto-resync once per session: scan, then analyze to completion,
            // exactly as clicking the buttons would. This branch only exists
            // while authorized, so it also fires right after the user grants.
            .task {
                guard !didAutoResync else { return }
                didAutoResync = true
                await scanner.scan(into: modelContext)
                // start() rescores and bumps RankingClock when it finishes.
                await analysisModel.start(container: modelContext.container).value
            }
        } else {
            authorizationPrompt
        }
    }

    private var limitedAccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true) // decorative — the text beside it already carries the meaning (FR-4.13)
                .help("Photos access is limited — Alpenglow only sees the photos you selected, so wallpapers can only come from that selection.")
            Text("Only your selected photos are available to Alpenglow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            // FR-1.2 wants a shortcut to *change the selection*, not just the
            // Privacy pane. PhotoKit's limited-library picker
            // (`presentLimitedLibraryPickerFromViewController:`) is
            // `API_UNAVAILABLE(macos)` — iOS/Catalyst only, no AppKit
            // counterpart exists as of macOS 27 beta 4 — so there's no way to
            // reopen the picker in-app. This falls back to the Privacy pane,
            // with a label that's honest about the extra step still needed
            // there (System Settings → Privacy & Security → Photos → Edit
            // Selected Photos) rather than implying a one-click reselect.
            Button("Change Selection in Settings…") { openPrivacySettings() }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Non-nil once a scan has finished; value changes when results change.
    private var scanCompletionToken: Int? {
        if case .finished(let candidates, _, let newlyAdded, let editedQueued, let removed) = scanner.phase {
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
            "Alpenglow needs to read your photo library to find wallpaper-worthy nature photos. Everything stays on your Mac."
        case .authorized:
            "Access granted."
        case .limited:
            "Limited access granted. Alpenglow can only see the photos you selected."
        case .denied:
            "Access denied. Enable Photos access in System Settings to continue."
        case .restricted:
            "Photos access is restricted on this Mac and can't be granted."
        @unknown default:
            "Unknown authorization status."
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
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
                    Text("Finds high-resolution landscape photos worth considering as wallpapers. Metadata only — fast, and nothing leaves your Mac.")
                        .foregroundStyle(.secondary)
                    scanButton(title: "Scan Library")

                case .scanning(let examined, let total):
                    ProgressView(value: total > 0 ? Double(examined) : nil, total: Double(max(total, 1)))
                    Text(total > 0 ? "\(examined) of \(total) photos examined" : "Preparing…")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                case .finished(let candidates, let examined, let newlyAdded, let editedQueued, let removed):
                    Label("\(candidates) wallpaper candidates", systemImage: "photo.stack")
                        .font(.callout.weight(.semibold))
                        .help("Photos whose size and shape qualify them for the wallpaper pipeline; Vision analysis filters them further.")
                    Text(scanSummary(examined: examined, newlyAdded: newlyAdded, editedQueued: editedQueued, removed: removed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    private func scanButton(title: String) -> some View {
        Button(title) {
            Task { await scanner.scan(into: modelContext) }
        }
        .buttonStyle(.borderedProminent)
    }
}

#Preview {
    ContentView()
}
