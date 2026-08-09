#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// Keeps a user-started analysis run going after the app leaves the
/// foreground, so a long run needs no babysitting (FR-3.6).
///
/// `BGContinuedProcessingTask` is the only API that fits the requirement's
/// shape: the user starts the work, it begins immediately rather than being
/// scheduled for some later idle moment, the system shows its own progress UI,
/// and that UI carries a cancel the user can hit at any time. The alternatives
/// don't fit — `BGProcessingTask` is system-scheduled and invisible, and
/// `beginBackgroundTask` buys seconds, not the length of a Vision pass.
///
/// **This path is unverified in this environment, and shipped knowing that.**
/// Apple DTS confirmed that the iOS 26 implementation stops progressing the
/// moment the device locks — the assertion intended to keep the device awake
/// was left off (developer.apple.com/forums/thread/796138). Nothing in the
/// iOS 27 SDK or its documentation says that was fixed, and it cannot be
/// checked here: no iOS runtime is installed, and lock-screen behaviour needs
/// a real device regardless. So treat "continues while locked" as untested.
/// What is *not* left to chance is the failure mode, and that part has been
/// watched rather than assumed. Running on an iPad simulator, where the
/// BackgroundTasks daemon isn't functional, `register` returned false and the
/// app logged "Background analysis unavailable: identifier not permitted;
/// continuing in the foreground only" — then analysed all seven candidates
/// normally, reported no background progress, and claimed nothing it wasn't
/// doing (FR-3.4). So the degradation path is observed behaviour, not a
/// hopeful comment. The same holds if the system never launches the task or
/// expires it early: `AnalysisModel`'s loop is untouched either way and simply
/// advances only while the app is on screen.
///
/// (The refusal was environmental, not a mis-set identifier: the installed
/// bundle's `BGTaskSchedulerPermittedIdentifiers` reads
/// `space.remco.Alpenglow.analysis.*`, exactly what is registered below.)
@MainActor
final class ContinuedAnalysisTask {
    /// Must stay in step with `BGTaskSchedulerPermittedIdentifiers` in
    /// Info.plist, which declares the wildcard form. The scheduler rejects any
    /// identifier not covered there with `BGTaskSchedulerErrorCodeNotPermitted`.
    private static var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "Alpenglow") + ".analysis"
    }

    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "ContinuedAnalysisTask")

    /// One owner for the whole process, because the thing it owns is
    /// process-wide: `BGTaskScheduler.register` binds an identifier once, for
    /// good, and the launch handler it installs outlives whatever object
    /// created it. A per-run instance cannot hold that — the handler would
    /// keep pointing at the first run's object while later runs got nothing,
    /// so from the second Analyze onwards the system would hand over a task
    /// nobody adopted: no expiration handler, never completed, and iOS
    /// penalises an app that leaves one dangling. A single long-lived owner
    /// that each run borrows is the shape the API actually has.
    static let shared = ContinuedAnalysisTask()

    private init() {}

    /// Set only once `register` has *succeeded*, so a refusal is retried on
    /// the next run rather than remembered as done.
    private var isRegistered = false

    private var task: BGContinuedProcessingTask?
    private var onCancel: (() -> Void)?
    private var pendingTotal: Int64 = 1
    private var pendingCompleted: Int64 = 0

    /// Asks the system to keep this run alive. Never throws: a refusal is a
    /// reason to carry on in the foreground, not to fail the user's analysis.
    func begin(onCancel: @escaping () -> Void) async {
        self.onCancel = onCancel

        if !isRegistered {
            // Captured strongly and deliberately: `shared` is immortal, and a
            // weak capture is exactly what made this fail before.
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "\(Self.identifierPrefix).*",
                using: .main
            ) { task in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                ContinuedAnalysisTask.shared.adopt(continued)
            }
            guard registered else {
                Self.log.error("Background analysis unavailable: identifier not permitted; continuing in the foreground only")
                return
            }
            isRegistered = true
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: "\(Self.identifierPrefix).\(UUID().uuidString)",
            title: "Analyzing Photos",
            subtitle: "Finding wallpaper candidates"
        )
        // Queue rather than fail: if the system can't start it this instant,
        // letting it start shortly is strictly better than not running at all.
        request.strategy = .queue

        do {
            // The async, completion-handler-backed submitTaskRequest(_:) is
            // iOS 27+ only; the deployment target is 26 (REQUIREMENTS.md's
            // opening), so submit(_:) — the same request type, still present
            // though deprecated as of 27 in favor of the async one — is the
            // fallback down to 26. Both report failure the same way to this
            // call site: a thrown error, handled identically below.
            //
            // submitTaskRequest(_:) isn't just runtime-gated by `#available`
            // — it isn't declared in the iOS 26 SDK at all, so a compiler
            // built against that SDK can't resolve the symbol (the CI
            // runner's Xcode 26.6 reports it as "renamed to submit(_:),
            // obsoleted in Swift 3" — an apinotes rename diagnostic landing
            // on an unresolved name, not a real Swift-3-era API). `#if
            // compiler(>=6.3)` gates the whole runtime-branching statement at
            // the toolchain boundary — Xcode 26.6 ships Swift 6.2, Xcode 27
            // ships Swift 6.4 — so it's only even parsed when compiling with
            // a toolchain new enough to declare the symbol; the 26-toolchain
            // build (every release build until the project's floor moves to
            // 27) falls straight to submit(_:), same as the runtime fallback
            // above already did for pre-27 devices.
            #if compiler(>=6.3)
            if #available(iOS 27, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            #else
            try BGTaskScheduler.shared.submit(request)
            #endif
        } catch {
            Self.log.error("Background analysis not started (\(error.localizedDescription, privacy: .public)); continuing in the foreground only")
        }
    }

    /// The system handed us the task: take ownership, seed its progress, and
    /// wire its cancel to the caller's stop.
    private func adopt(_ task: BGContinuedProcessingTask) {
        // A task can arrive with no run to attach it to — the run finished
        // while the request was still queued, or was stopped before the system
        // got to it. Completing it immediately is the honest answer; holding it
        // would leave exactly the dangling task this class exists to avoid.
        guard onCancel != nil else {
            task.setTaskCompleted(success: true)
            return
        }
        // Likewise if one is already held: adopting a second would silently
        // orphan the first.
        guard self.task == nil else {
            task.setTaskCompleted(success: true)
            return
        }
        self.task = task
        task.progress.totalUnitCount = pendingTotal
        task.progress.completedUnitCount = pendingCompleted
        // Fired both when the user cancels from the system's UI and when the
        // system reclaims the task. Either way the honest response is the same
        // one the in-app Stop button gives: end the run. Analysis saves per
        // batch, so nothing is lost and it resumes where it stopped (FR-3.3).
        task.expirationHandler = { [weak self] in
            Self.log.info("Background analysis ended by the system or the user")
            self?.onCancel?()
        }
    }

    /// Feeds the system's progress UI. `BGContinuedProcessingTask` requires
    /// progress reporting and may reclaim a task that looks stalled, so this
    /// is called on every batch, and the values are retained so a task adopted
    /// later starts from the right place rather than at zero.
    func update(completed: Int, total: Int) {
        pendingCompleted = Int64(completed)
        pendingTotal = Int64(max(total, 1))
        guard let progress = task?.progress else { return }
        progress.totalUnitCount = pendingTotal
        progress.completedUnitCount = pendingCompleted
    }

    /// Releases the task. Must be called however the run ends — the system
    /// penalises an app that leaves one dangling.
    func end(success: Bool) {
        task?.setTaskCompleted(success: success)
        task = nil
        onCancel = nil
    }
}
#endif
