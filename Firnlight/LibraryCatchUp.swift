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
/// A fourth thing stands a catch-up *down* without starting one:
/// `authorizationNarrowingRecheckTask`, a slow timer that re-reads
/// authorization on its own. It exists only because FR-1.8's "including when
/// access is narrowed while the app is open" can't be proven to follow from
/// the change notification alone — see `checkForNarrowedAccess` and
/// `Thresholds.authorizationNarrowingRecheckInterval`.
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

    private let log = Logger(subsystem: "space.remco.Firnlight", category: "LibraryCatchUp")

    /// The main context to scan into, and the authorization to re-read when
    /// the library reports a change. Both are handed over by `begin` and held
    /// rather than passed per call, because the change notification arrives
    /// from PhotoKit with no view in sight to supply them.
    private var context: ModelContext?
    private var authorization: PhotoLibraryAuthorization?

    private var watcher: PhotoLibraryWatcher?
    private var task: Task<Void, Never>?
    private var againRequested = false
    /// The slow fallback recheck described on the type's own doc comment.
    private var authorizationNarrowingRecheckTask: Task<Void, Never>?

    /// Starts watching the library and catches up with it now. Safe to call
    /// repeatedly — the watcher is registered once.
    func begin(context: ModelContext, authorization: PhotoLibraryAuthorization) {
        self.context = context
        self.authorization = authorization
        if watcher == nil {
            watcher = PhotoLibraryWatcher { [weak self] in
                // Delivered on an arbitrary queue; everything this touches is
                // main-actor state.
                Task { @MainActor in await self?.libraryDidChange() }
            }
        }
        if authorizationNarrowingRecheckTask == nil {
            authorizationNarrowingRecheckTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Thresholds.authorizationNarrowingRecheckInterval)
                    guard !Task.isCancelled else { break }
                    await self?.checkForNarrowedAccess()
                }
            }
        }
        request(afterSettling: false)
    }

    /// Stops watching and stands the pipeline down — called when access is no
    /// longer full (FR-1.8), which is the only way the app goes from working
    /// to not working while it is open.
    ///
    /// Async because standing down means more than stopping this
    /// coordinator's own coalescing loop: FR-1.8 says the app "does nothing"
    /// once access is narrowed, and `AnalysisModel`'s run task is Vision work
    /// and iCloud downloads that keep going in the background regardless of
    /// what this type's own `task` is doing — cancelling only the latter left
    /// the pipeline visibly still working after the app had told the user it
    /// could not. `standDownForCatchUp` is what `runOnce` already uses to get
    /// the store to itself before a scan; reusing it here waits out the same
    /// tail-end rescore rather than leaving it racing a `.task(id:)` that has
    /// already unmounted the authorized UI.
    func end() async {
        watcher = nil
        authorizationNarrowingRecheckTask?.cancel()
        authorizationNarrowingRecheckTask = nil
        task?.cancel()
        task = nil
        againRequested = false
        await analysis.standDownForCatchUp()
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

    private func libraryDidChange() async {
        // A change notification is expected to be how the app finds out its
        // access was narrowed to a selection without ever leaving the screen
        // — see `checkForNarrowedAccess` for how sure that expectation is,
        // and `authorizationNarrowingRecheckTask` for the fallback that
        // doesn't depend on it.
        guard await checkForNarrowedAccess() else { return }
        request(afterSettling: true)
    }

    /// Re-reads Photos authorization and stands the pipeline down if it no
    /// longer covers the whole library (FR-1.8). Returns whether the caller
    /// should proceed as still-authorized.
    ///
    /// Called from two places that don't trust each other to be sufficient
    /// alone: `libraryDidChange`, on the assumption — undocumented by Apple
    /// and unverified on a device here — that narrowing full access to a
    /// selection fires `photoLibraryDidChange` the same way a change *within*
    /// an existing selection does; and `authorizationNarrowingRecheckTask`,
    /// the slow timer that catches the case a foregrounded, idle app would
    /// otherwise miss if that assumption is wrong. See the type's own doc
    /// comment and `PhotoLibraryWatcher.photoLibraryDidChange`.
    @discardableResult
    private func checkForNarrowedAccess() async -> Bool {
        authorization?.refresh()
        guard authorization?.isAuthorized == true else {
            log.info("Library access is no longer full; standing down")
            await end()
            return false
        }
        return true
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
