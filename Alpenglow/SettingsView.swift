import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The app's settings, and the only settings it has.
///
/// FR-8.10 keeps this to what the brief actually asks for, and every section
/// below names its clause: turning the Photos-change alerts back on (FR-1.9),
/// copying judgments off the device and restoring them (FR-7.4), starting a
/// taste over (FR-7.5), and agreeing — or not — to the app looking for newer
/// releases (FR-10.8). There is no "Wi-Fi only", no thermal preference and no
/// album-name field: the app takes those from the system or from the brief,
/// and a setting the requirements don't ask for is one more thing to read and
/// maintain.
///
/// One view, two homes, because the platforms disagree about where settings
/// live: on the Mac it is the standard Settings window behind ⌘, (see
/// `AlpenglowApp`), and on iPhone and iPad a sheet from the foot of the Export
/// tab (see `ExportView`) — iOS's own Settings app can only show static
/// strings from a `Settings.bundle`, which could carry neither these switches
/// nor a button.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    /// Mirrors of the stored consent, so the switches redraw when flipped.
    /// Re-read on appearance, because the alert's "Always Allow" writes the
    /// same defaults from somewhere else entirely (FR-1.9).
    @State private var askBeforeCreatingAlbum = true
    @State private var askBeforeChangingAlbum = true

    /// The one checker the whole app shares — the same object the Library
    /// tab's notice reads, so agreeing here is what makes that notice possible
    /// and withdrawing here is what takes it away. Plain `let`: `@Observable`
    /// tracks reads made in `body` whatever holds the reference.
    private let updates = UpdateCheck.shared

    @State private var exportDocument: JudgmentArchiveDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isWorking = false
    /// The last thing that happened to the judgments — a restore's tally, or a
    /// failure. Never cleared on the way in to the next attempt, so redoing
    /// something moves nothing (FR-8.7).
    @State private var judgmentStatus: String?
    @State private var judgmentFailed = false
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle(PhotosChangeKind.createAlbum.settingsLabel, isOn: $askBeforeCreatingAlbum)
                    .onChange(of: askBeforeCreatingAlbum) { _, ask in
                        PhotosChangeConsent.setShouldAsk(.createAlbum, ask)
                    }
                Toggle(PhotosChangeKind.changeAlbum.settingsLabel, isOn: $askBeforeChangingAlbum)
                    .onChange(of: askBeforeChangingAlbum) { _, ask in
                        PhotosChangeConsent.setShouldAsk(.changeAlbum, ask)
                    }
            } header: {
                Text("Changes in Photos")
            } footer: {
                Text("Creating the “\(Thresholds.wallpaperAlbumName)” album and setting what’s in it are the only changes Alpenglow ever makes in Photos — your photos themselves are never edited or deleted.")
            }

            Section {
                Button("Copy Judgments to a File…") { exportJudgments() }
                    .disabled(isWorking)
                Button("Restore Judgments from a File…") { isImporting = true }
                    .disabled(isWorking)
                if let judgmentStatus {
                    Text(judgmentStatus)
                        .font(.callout)
                        .foregroundStyle(judgmentFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Your Judgments")
            } footer: {
                Text("Your duels, verdicts and ignored photos are the one thing Alpenglow can’t work out again. A copy restores here or on another device; restoring adds to what’s already here rather than replacing it.")
            }

            Section {
                Toggle("Check for new releases", isOn: Binding(
                    get: { updates.consent == true },
                    set: { updates.setConsent($0) }
                ))
                if let line = updateStatus {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(updates.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .available(_, let url) = updates.availability {
                    Link("Open the release page", destination: url)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Alpenglow is downloaded from GitHub rather than an app store, so nothing tells you a fix exists unless it asks. The check sends nothing about you or your library.")
            }

            Section {
                Button("Start My Taste Over…", role: .destructive) { isConfirmingReset = true }
                    .disabled(isWorking)
            } header: {
                Text("Start Over")
            } footer: {
                Text("Goes: \(JudgmentArchive.resetGoesAway)\n\nStays: \(JudgmentArchive.resetStays)")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // The Settings window sizes to its content, and a form of switches is
        // narrower than a settings window should be.
        .frame(minWidth: 420, idealWidth: 480)
        #endif
        .onAppear {
            askBeforeCreatingAlbum = PhotosChangeConsent.shouldAsk(.createAlbum)
            askBeforeChangingAlbum = PhotosChangeConsent.shouldAsk(.changeAlbum)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: JudgmentArchive.contentType,
            defaultFilename: JudgmentArchive.defaultFilename
        ) { result in
            switch result {
            case .success(let url):
                judgmentFailed = false
                judgmentStatus = "Copied your judgments to “\(url.lastPathComponent)”."
            case .failure(let error):
                // FR-8.12: a copy that didn't happen never reads as one that did.
                judgmentFailed = true
                judgmentStatus = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [JudgmentArchive.contentType]
        ) { result in
            switch result {
            case .success(let url):
                restoreJudgments(from: url)
            case .failure(let error):
                judgmentFailed = true
                judgmentStatus = error.localizedDescription
            }
        }
        // FR-7.5: never by accident. The destructive act is named in the
        // button, asked again here, and the footer above has already said what
        // goes and what stays before the question is put.
        .confirmationDialog(
            "Start your taste over?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Start Over", role: .destructive) { resetTaste() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Goes: \(JudgmentArchive.resetGoesAway)\n\nStays: \(JudgmentArchive.resetStays)")
        }
    }

    private var updateStatus: String? {
        if let error = updates.lastError { return error }
        switch updates.availability {
        case .unknown:
            return updates.consent == true ? nil : "Alpenglow hasn’t checked, and won’t until you turn this on."
        case .upToDate:
            return "Alpenglow \(AppIdentity.version) is the newest release."
        case .available(let version, _):
            return "Alpenglow \(version) is available. You have \(AppIdentity.version)."
        }
    }

    private func exportJudgments() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let data = try await JudgmentArchive.export(container: modelContext.container)
                exportDocument = JudgmentArchiveDocument(data: data)
                isExporting = true
            } catch {
                judgmentFailed = true
                judgmentStatus = error.localizedDescription
            }
        }
    }

    private func restoreJudgments(from url: URL) {
        isWorking = true
        Task {
            defer { isWorking = false }
            // A file chosen through the importer arrives security-scoped on
            // both platforms; reading it without claiming the scope fails with
            // a permission error the user could do nothing about.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let summary = try await JudgmentArchive.restore(from: data, container: modelContext.container)
                judgmentFailed = false
                judgmentStatus = summary.isEmpty
                    ? "Nothing new — every judgment in that file was already here."
                    : "Restored \(summary.choices) choices, \(summary.verdicts) verdicts and \(summary.ignores) ignored photos."
                // Restored judgments are judgments: the ranking, the grid, the
                // duel pool and the album suggestion all rest on them (FR-4.5).
                RankingClock.shared.bump()
            } catch {
                judgmentFailed = true
                judgmentStatus = error.localizedDescription
            }
        }
    }

    private func resetTaste() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await JudgmentArchive.resetLearnedTaste(container: modelContext.container)
                judgmentFailed = false
                judgmentStatus = "Your taste has been reset. Ranking starts from your Photos favorites again."
                RankingClock.shared.bump()
            } catch {
                judgmentFailed = true
                judgmentStatus = error.localizedDescription
            }
        }
    }
}

/// The archive as a document, which is all `fileExporter` will carry.
///
/// `nonisolated` because `FileDocument`'s requirements are: it is read and
/// written on whatever queue the system picks, and the payload is a `Data` it
/// was handed.
nonisolated struct JudgmentArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [JudgmentArchive.contentType] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
