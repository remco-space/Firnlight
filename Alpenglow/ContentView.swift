import SwiftUI
import SwiftData
import Photos

struct ContentView: View {
    @State private var authorization = PhotoLibraryAuthorization()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Library", systemImage: "photo.on.rectangle.angled") {
                LibraryTab(authorization: authorization)
            }
            Tab("Duel", systemImage: "rectangle.split.2x1") {
                DuelView()
            }
            Tab("Export", systemImage: "square.and.arrow.up") {
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
    @State private var scanner = LibraryScanner()
    @State private var analysisModel = AnalysisModel()

    /// Guards the once-per-session startup auto-resync.
    @State private var didAutoResync = false

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
            // Auto-resync once per session: scan, then analyze to completion,
            // exactly as clicking the buttons would. This branch only exists
            // while authorized, so it also fires right after the user grants.
            .task {
                guard !didAutoResync else { return }
                didAutoResync = true
                await scanner.scan(into: modelContext)
                await analysisModel.start(container: modelContext.container).value
                RankingClock.shared.bump()
            }
        } else {
            authorizationPrompt
        }
    }

    private var limitedAccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Only your selected photos are available to Alpenglow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Open Photos Settings") { openPrivacySettings() }
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
            case .denied, .restricted:
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
                    Text(scanSummary(examined: examined, newlyAdded: newlyAdded, editedQueued: editedQueued, removed: removed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    scanButton(title: "Scan Again")

                case .failed(let message):
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
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
