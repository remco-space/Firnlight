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

    /// The pipeline that keeps the app current with the library (FR-2.7),
    /// owned here rather than by the Library tab that displays it: a `TabView`
    /// only builds the *selected* tab, and catching up has to happen whichever
    /// tab the user was last on. It is also what the tab's own progress reads,
    /// so a launch catch-up and a change-driven one are visibly the same run.
    @State private var catchUp = LibraryCatchUp()

    /// FR-10.8. Shared with the settings switch that turns it on and off — see
    /// `UpdateCheck.shared`.
    private let updates = UpdateCheck.shared
    /// The one time the app puts the question. Raised once the library is
    /// usable rather than at the first frame, so a first launch shows the
    /// Photos-access screen alone instead of stacking an unrelated alert on
    /// top of it.
    @State private var isAskingAboutUpdates = false

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
                LibraryTab(authorization: authorization, catchUp: catchUp, updates: updates)
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
            guard newPhase == .active else { return }
            // Pick up grants made in System Settings while we were in the
            // background (FR-1.3), and narrowings made the same way (FR-1.8).
            authorization.refresh()
            // Pick a run back up that the system ended while the app was away,
            // or one whose deferred iCloud work may now be possible (FR-3.4,
            // FR-3.6). Deliberately *not* a whole catch-up: the library
            // reports its own changes (see `LibraryCatchUp`), so walking it
            // again on every switch back to the app would be work with a known
            // answer.
            catchUp.resumeIfWorkRemains()
        }
        // FR-2.7: with access to the whole library, the app catches up on its
        // own — at launch and from then on as Photos reports changes — with
        // nothing for the user to press.
        //
        // Attached to the TabView, not to the Library tab that shows the
        // progress, because `TabView` only builds the *selected* tab: while
        // this lived in `LibraryTab.task`, FR-8.1 restoring the user to Export
        // or Duel meant the tab never mounted and the catch-up silently never
        // ran. It is unconditional, so its trigger has to hang off something
        // that exists on every launch regardless of tab.
        //
        // `.task(id:)` on the authorization state rather than a plain `.task`:
        // the pipeline must also start the moment the user grants access
        // without relaunching (FR-1.3), which is exactly when this id flips —
        // and must stand down the moment access is narrowed to a selection
        // (FR-1.8), which is when it flips back.
        //
        // Nothing about *where* the work runs changes: the scan yields
        // cooperatively and analysis runs in its own actor off the main thread,
        // so the rest of the app stays live behind their progress (FR-8.2), and
        // switching to Library mid-run picks up the same observable models
        // already counting up (FR-2.4, FR-4.11).
        .task(id: authorization.isAuthorized) {
            guard authorization.isAuthorized else {
                catchUp.end()
                return
            }
            // Deliberately no album work here. Recovering an interrupted sync
            // (FR-6.8) is offered in the Export tab instead of done on launch,
            // because these devices share one album and FR-6.10 forbids
            // changing it unattended — see WallpaperAlbumSync.restoreInterruptedSync.
            catchUp.begin(context: modelContext, authorization: authorization)

            // FR-10.8, in the order the requirement puts it: agreement first,
            // then — and only then — a check.
            if updates.hasBeenAsked {
                await updates.checkIfAgreed()
            } else {
                isAskingAboutUpdates = true
            }
        }
        .alert("Let Alpenglow check for new releases?", isPresented: $isAskingAboutUpdates) {
            // Both answers are final, which is why neither is worded as "not
            // now": the question is asked once, and the switch in Settings is
            // where either answer is changed later.
            Button("Don’t Check") { updates.setConsent(false) }
            Button("Check for Releases") { updates.setConsent(true) }
        } message: {
            Text("Alpenglow is downloaded from GitHub rather than an app store, so it can only tell you a newer version exists by asking GitHub. It sends nothing about you or your library, and you can change this in Settings.")
        }
    }
}

/// Library tab: Photos authorization, then the pipeline's progress and the
/// ranked grid.
private struct LibraryTab: View {
    let authorization: PhotoLibraryAuthorization
    /// Owned by `ContentView`, because catching up runs from outside any tab.
    /// This tab renders its progress, so a catch-up the launch started and one
    /// a library change started are visibly the same run.
    let catchUp: LibraryCatchUp
    let updates: UpdateCheck

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    // FR-8.1: restore roughly where the user had scrolled to. Seeded from the
    // persisted vertical offset at view-creation time, so SwiftUI applies it
    // as the ScrollView's *initial* position once content lays out — there's
    // no separate "wait for the grid, then scroll" step to get right.
    //
    // Fidelity trade-off, deliberate: this restores a raw pixel offset, not a
    // specific photo's position. The Library tab's content is the pipeline
    // cards followed by the ranked grid, and the grid re-orders
    // itself between launches as duels retrain the ranking (FR-4.5) — so a
    // pixel-perfect "same photo under the cursor" restore is impossible
    // anyway (the content at that offset isn't guaranteed to be the same). An
    // approximate return to the same scrolled region is what FR-8.1 asks for
    // and what this delivers; a per-item anchor would be more precise for the
    // grid specifically but couldn't survive the cards above it changing
    // height (e.g. a summary appearing) between launches either.
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
                        if case .available(let version, let url) = updates.availability {
                            updateNotice(version: version, url: url)
                        }
                        LibraryStatusView(scanner: catchUp.scanner)
                        AnalysisView(model: catchUp.analysis, scanToken: scanCompletionToken)
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
            // FR-8.3: lets the menu bar's Stop and Resume act on the same run
            // this tab's own control does. Published only in this authorized
            // branch, so the commands are disabled for free whenever the whole
            // library isn't available — see AppCommands.swift.
            .focusedSceneValue(\.libraryCommandTarget, LibraryCommandTarget(
                analysisModel: catchUp.analysis,
                modelContext: modelContext
            ))
        } else {
            authorizationPrompt
        }
    }

    /// FR-10.8: a newer release exists, and here is where to get it.
    ///
    /// Only ever drawn when the user has agreed to the check (nothing else can
    /// produce an `.available`), and only in the Library tab — the app's first
    /// screen, and one place rather than three saying the same thing (FR-8.10).
    /// It arrives and stays, which FR-8.7 allows to take room, and it sits
    /// above content rather than above a control anybody was reaching for.
    private func updateNotice(version: String, url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true) // decorative — the text beside it carries the meaning (FR-4.13)
            Text("Alpenglow \(version) is available. You have \(AppIdentity.version).")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Get It…") { openURL(url) }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Non-nil once a catch-up has finished; value changes when results change.
    private var scanCompletionToken: Int? {
        if case .finished(let candidates, _, let newlyAdded, let editedQueued, let removed) = catchUp.scanner.outcome {
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
            case .denied, .limited:
                // `.limited` shares the button because it shares the remedy:
                // there is no API to re-prompt for full access or to widen a
                // selection (see `PhotoLibraryAuthorization.settingsURL`), so
                // the privacy settings are the only route from a selection to
                // the whole library (FR-1.8).
                //
                // `.restricted` (parental controls/MDM) has no button here:
                // Privacy Settings can't grant it — only the managing admin
                // can — so offering the same shortcut would be a dead end.
                // `statusMessage` above already explains why.
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
            // FR-1.8: a selection is not a smaller library, it is a different
            // job the app can't do — it can't tell a photo you deleted from
            // one you didn't select, and Photos won't let it maintain an album
            // at all. Saying so beats appearing to work.
            #if os(macOS)
            "Alpenglow only has access to selected photos, which isn’t enough to keep the wallpaper album or notice photos you delete. Allow access to all photos in System Settings → Privacy & Security → Photos."
            #else
            "Alpenglow only has access to selected photos, which isn’t enough to keep the wallpaper album or notice photos you delete. Allow access to all photos in Settings."
            #endif
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
    /// per-platform destination lives on `PhotoLibraryAuthorization`; opening
    /// it is the same `openURL` on both platforms.
    private func openPrivacySettings() {
        guard let url = PhotoLibraryAuthorization.settingsURL else { return }
        openURL(url)
    }
}

/// What the app is doing about the library, and what it last found (FR-2.4).
///
/// There is no control in here, and that is the requirement rather than an
/// omission: FR-2.7 says the app is always current and that there is no
/// re-scan, "because there is nothing a re-scan would find that the app has
/// not already found". What replaced the button is `LibraryCatchUp` — the app
/// catches up at launch and follows the library's own change notifications
/// from then on. So this card reports, and reporting is all it does.
private struct LibraryStatusView: View {
    let scanner: LibraryScanner

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Library")
                    .font(.headline)

                // Fixed order, every phase: blurb, progress, outcome. The only
                // thing that ever changes height is `outcome`, at the bottom,
                // where FR-8.7 allows a result to take room.
                Text("Alpenglow keeps up with your library on its own, watching for photos added, edited or deleted. It looks for high-resolution landscape photos worth considering as wallpapers — metadata only, and nothing leaves your device.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                progressRow

                outcome
            }
            .padding(8)
            // Matches `AnalysisView`'s card — see the note there for why the
            // stretch has to be applied inside the `GroupBox` rather than to
            // it. Both cards carry this so they render the same width; giving
            // it to only one would trade one mismatch for another.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The running count, in a slot that is there whether or not a pass is.
    ///
    /// Built unconditionally and faded rather than inserted, per FR-8.7: every
    /// pass is now the app's own work — nobody asks for one — so inserting
    /// these two rows when one began would push the analysis card and the
    /// whole candidate grid down the page with no act of the user's behind it.
    /// Reserving the rows for good costs a fixed strip of empty card and buys a
    /// column that never jumps. `shownWhileWaiting` supplies FR-2.4's other
    /// half — "a change small enough to be instant simply appears": a pass that
    /// beats `Thresholds.noticeableWaitDelay` finishes without ever flashing a
    /// bar nobody could have read.
    private var progressRow: some View {
        let progress = scanProgress
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.value, total: progress.total)
                // Pinned to the linear style, in both states. Left to itself a
                // `ProgressView` with no value draws as a *circular* spinner,
                // and a bar that turned into a spinner and back mid-pass would
                // resize the row this slot exists to keep still (FR-8.7).
                // Named explicitly, the indeterminate and determinate forms are
                // the same bar in the same track.
                .progressViewStyle(.linear)
            Text(progress.caption)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .shownWhileWaiting(scanner.isScanning)
    }

    /// Indeterminate until the library's size is known, determinate after —
    /// and exactly one line of caption throughout.
    ///
    /// The `nil` value is deliberate, and it is the one place this row is
    /// allowed to change what it draws. `PHAsset.fetchAssets` has to come back
    /// before there is any denominator to count against, and on a large cold
    /// library that gap outlasts `Thresholds.noticeableWaitDelay`, so the slot
    /// is on screen for it. A determinate bar sitting at zero for those
    /// seconds reads as work that has stalled, which is the opposite of the
    /// live progress FR-2.4 promises; an indeterminate bar says "working, no
    /// count yet", which is the truth. It costs nothing under FR-8.7 because
    /// `.progressViewStyle(.linear)` above keeps both forms the same size —
    /// only the fill changes, not the geometry.
    ///
    /// A one-line caption for the same reason as the fixed slot: the longest
    /// count must not wrap and grow the row. The values outside `.scanning`
    /// are only ever rendered at zero opacity, so they just have to keep the
    /// slot the size it will need.
    private var scanProgress: (value: Double?, total: Double, caption: String) {
        guard case .scanning(let examined, let total) = scanner.phase, total > 0 else {
            return (nil, 1, "Preparing…")
        }
        return (Double(examined), Double(total), "\(examined) of \(total) photos examined")
    }

    /// What the app last found in the library.
    ///
    /// It reads `scanner.outcome`, not `scanner.phase`, and so survives the
    /// next pass: the previous summary stays put for the whole run and is
    /// swapped for the new one at the instant that one exists. FR-8.7 asks
    /// that redoing something move nothing *at all*, and clearing the summary
    /// only to refill the same space a few seconds later is the exact shape it
    /// names.
    @ViewBuilder
    private var outcome: some View {
        if let outcome = scanner.outcome {
            outcomeContent(outcome)
        }
    }

    @ViewBuilder
    private func outcomeContent(_ outcome: LibraryScanner.Outcome) -> some View {
        switch outcome {
        case .finished(let candidates, let examined, let newlyAdded, let editedQueued, let removed):
            Label("\(candidates) wallpaper candidates", systemImage: "photo.stack")
                .font(.callout.weight(.semibold))
                .help("Photos whose size and shape qualify them for the wallpaper pipeline; Vision analysis filters them further.")
            Text(scanSummary(examined: examined, newlyAdded: newlyAdded, editedQueued: editedQueued, removed: removed))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            // FR-8.12: a pass that failed says so, rather than leaving the
            // last good summary to imply the app is current when it isn't.
            Label("Couldn't read the library", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("The last pass over the library stopped with the error below; Alpenglow tries again the next time your library changes.")
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
}

#Preview {
    ContentView()
}
