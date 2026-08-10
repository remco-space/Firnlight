import Foundation
import SwiftData
import Observation
import os

/// Keeps the app current with the user's library, with nothing for the user to
/// press (FR-2.7).
///
/// It owns the two halves of the pipeline — the metadata pass
/// (`LibraryScanner`) and the Vision run (`AnalysisModel`) — because "always
/// current" is a property of the two together, not of either alone: a change in
/// Photos means a pass over the library, and a pass that finds anything means
/// analysis has work to do. Owning both is also what lets the two be
/// *sequenced*, which they must be (see `runOnce`).
///
/// Three things start a catch-up, and none of them is a control:
///
/// - **The app opening on an authorized library** (`begin`), which is FR-2.7's
///   "catches up at launch".
/// - **Photos reporting a change** (`PhotoLibraryWatcher`), which is the rest
///   of it: a deleted photo drops out, an edited one is re-examined, a new one
///   is picked up, all while the app is open (FR-2.5, FR-2.6). This is the
///   mechanism that makes a re-scan control pointless rather than merely
///   unfashionable — by the time the user could press it, the app has already
///   been told.
/// - **The app coming back to the foreground** (`resumeIfWorkRemains`), which
///   picks a run back up after the system ended one, without repeating the
///   library pass.
///
/// Overlapping requests coalesce rather than queue: a request arriving while a
/// catch-up runs is remembered and honoured once at the end, so a burst of
/// changes costs one extra pass, not one per notification. On top of that a
/// change-driven catch-up waits `Thresholds.libraryChangeSettleDelay` first,
/// because a single user action in Photos rarely produces a single
/// notification.
@MainActor
@Observable
final class LibraryCatchUp {
    let scanner = LibraryScanner()
    let analysis = AnalysisModel()

    private let log = Logger(subsystem: "space.remco.Alpenglow", category: "LibraryCatchUp")

    /// The main context to scan into, and the authorization to re-read when
    /// the library reports a change. Both are handed over by `begin` and held
    /// rather than passed per call, because the change notification arrives
    /// from PhotoKit with no view in sight to supply them.
    private var context: ModelContext?
    private var authorization: PhotoLibraryAuthorization?

    private var watcher: PhotoLibraryWatcher?
    private var task: Task<Void, Never>?
    private var againRequested = false

    /// Starts watching the library and catches up with it now. Safe to call
    /// repeatedly — the watcher is registered once.
    func begin(context: ModelContext, authorization: PhotoLibraryAuthorization) {
        self.context = context
        self.authorization = authorization
        if watcher == nil {
            watcher = PhotoLibraryWatcher { [weak self] in
                // Delivered on an arbitrary queue; everything this touches is
                // main-actor state.
                Task { @MainActor in self?.libraryDidChange() }
            }
        }
        request(afterSettling: false)
    }

    /// Stops watching and stands the pipeline down — called when access is no
    /// longer full (FR-1.8), which is the only way the app goes from working
    /// to not working while it is open.
    func end() {
        watcher = nil
        task?.cancel()
        task = nil
        againRequested = false
    }

    /// Picks up a run the app should be making anyway, without a library pass:
    /// the cheap half of catching up, for coming back to the foreground after
    /// the system ended a run (FR-3.6) or the app was away long enough for a
    /// deferred download to become possible (FR-3.4).
    func resumeIfWorkRemains() {
        guard let context, !analysis.isRunning else { return }
        guard let stats = analysis.stats, stats.pending + stats.skipped > 0 else { return }
        analysis.startUnlessStopped(container: context.container)
    }

    private func libraryDidChange() {
        // A change notification is also how the app finds out its access was
        // narrowed to a selection without ever leaving the screen — changing
        // the selection *is* a library change (FR-1.8).
        authorization?.refresh()
        guard authorization?.isAuthorized == true else {
            log.info("Library access is no longer full; standing down")
            end()
            return
        }
        request(afterSettling: true)
    }

    private func request(afterSettling: Bool) {
        guard context != nil else { return }
        guard task == nil else {
            againRequested = true
            return
        }
        task = Task {
            if afterSettling {
                try? await Task.sleep(for: Thresholds.libraryChangeSettleDelay)
            }
            while !Task.isCancelled {
                againRequested = false
                await runOnce()
                // No suspension point between this test and clearing `task`,
                // so a request made from the main actor either sets the flag
                // in time to be seen here or finds no task to coalesce into.
                if !againRequested { break }
            }
            task = nil
        }
    }

    /// One pass: stand analysis down, reconcile the store with the library,
    /// start analysis again.
    ///
    /// The sequence is the point. The scan walks and rewrites the very records
    /// the analysis queue is reading and stamping, from a different
    /// `ModelContext`, so letting them overlap is a race over the same rows.
    /// Standing the run down costs nothing that isn't recovered — analysis
    /// saves per batch and resumes where it stopped (FR-7.1) — and the restart
    /// is what keeps newly found photos from waiting for a control that no
    /// longer exists (FR-3.5).
    ///
    /// The restart is deliberately not awaited: a run holding deferred iCloud
    /// work does not end (FR-3.4), so awaiting it would mean no further
    /// catch-up ever ran.
    private func runOnce() async {
        guard let context else { return }
        await analysis.standDownForCatchUp()
        await scanner.scan(into: context)
        analysis.startUnlessStopped(container: context.container)
    }
}
