import Foundation
// For `LocalizedStringKey`: `detail` is help text, and `.help` takes a key, not
// a `String` — passing a String there would opt the sentence out of
// localization at the one call site that has to have it.
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

/// What an unattended analysis run cannot promise on this device, in the
/// user's own terms (FR-3.6, FR-8.12).
///
/// FR-3.6 asks for two things of a long run: that it keep going while nobody
/// is watching, *and* that wherever the platform would suspend it anyway, the
/// app say so rather than let the user believe work is still happening. The
/// second half is what this enum carries — one sentence, shown beside the
/// running analysis, naming the thing that will stop it.
///
/// Deliberately not a "wait" (`AnalysisWait`): nothing is being waited for and
/// the run is working normally. It is a standing statement about this run's
/// reach, which is why it is shown for as long as the run lasts rather than
/// appearing when some condition trips.
///
/// `CaseIterable` for the same reason `AnalysisWait` is: `AnalysisView` lays
/// out every message this can carry and reserves the taller of them before the
/// run starts, so switching between them (plugging in, unplugging) moves
/// nothing (FR-8.7).
nonisolated enum UnattendedRunLimit: Sendable, Equatable, CaseIterable {
    #if os(macOS)
    /// On mains power: the app holds off idle sleep for as long as the run
    /// lasts, so the only thing that still ends it is the Mac genuinely
    /// sleeping — which the user can always cause, and which closing the lid
    /// of a laptop with no external display causes unconditionally, no matter
    /// what any app asks for.
    case macSleepsAnyway
    /// On battery: the app does *not* hold off idle sleep. FR-3.6's promise is
    /// "on power", and quietly keeping a laptop awake to burn its battery on
    /// wallpaper analysis is the opposite of what the same requirement asks
    /// for two sentences later.
    case macOnBattery
    #else
    /// The app asks the system to continue the run once it leaves the
    /// foreground, and the system decides how long that lasts. It is not the
    /// app's to guarantee, so it isn't presented as one.
    case deviceMayPauseWhenLocked
    #endif

    /// One short line — this sits under a run that is working, and a paragraph
    /// there would read as something having gone wrong. The rest is in
    /// `detail`, the way the card's rejection counts already carry their
    /// explanation.
    var message: String {
        switch self {
        #if os(macOS)
        case .macSleepsAnyway:
            "Keeps analyzing while you're away, until the Mac sleeps."
        case .macOnBattery:
            "On battery, analyzing stops when the Mac sleeps."
        #else
        case .deviceMayPauseWhenLocked:
            "Continues after you leave the app, for as long as the system allows."
        #endif
        }
    }

    /// The whole of it: what the app does, what still stops it, and that
    /// nothing is lost when it does.
    var detail: LocalizedStringKey {
        switch self {
        #if os(macOS)
        case .macSleepsAnyway:
            "Firnlight holds the Mac out of idle sleep while it analyzes on power. Sleep the user asks for still stops it — closing the lid of a Mac with no external display sleeps it whatever any app wants — and analyzing carries on where it left off when the Mac wakes."
        case .macOnBattery:
            "Firnlight doesn't hold a Mac awake on battery. Plug in to keep a long run going while you're away; either way, analyzing carries on where it left off when the Mac wakes."
        #else
        case .deviceMayPauseWhenLocked:
            "Firnlight asks the system to continue the run once you leave the app, and the system decides how long that lasts — locking the device may end it. Analyzing carries on where it left off when you come back."
        #endif
        }
    }
}

/// Keeps a user-started analysis run going while nobody is watching, on the
/// platform that has no BackgroundTasks (FR-3.6). The iOS half of the same
/// requirement is `ContinuedAnalysisTask`.
///
/// On the Mac the danger to a long run is not the app being backgrounded — a
/// Mac app keeps running behind other windows, and a sleeping *display* never
/// suspended anything — but the system going to idle sleep on its own while
/// the user is away from the keyboard. `ProcessInfo`'s activity API is the
/// documented way to say "I am doing something the user started, don't idle
/// away underneath it"; it is not a private power assertion and needs no
/// entitlement, so it works from inside the app sandbox. `.userInitiated`
/// already implies `.idleSystemSleepDisabled`; both are named for the reader.
/// The display is left free to sleep — `idleDisplaySleepDisabled` is not
/// asked for — because a dark screen is what an unattended machine should
/// look like, and it doesn't cost the run anything.
///
/// Held only while the Mac is on mains power, which is exactly the promise
/// FR-3.6 makes ("keeps going unattended, **on power**"). What the assertion
/// cannot do is override the sleep the *user* asks for, including closing the
/// lid of a laptop with no external display attached: that path sleeps the
/// machine regardless of what any app has requested, which is why this class
/// pairs the assertion with a `limit` the UI states rather than a claim that
/// nothing can interrupt a run.
///
/// Verified with `pmset -g assertions`, which lists
/// `PreventUserIdleSystemSleep` naming this app and this reason for exactly as
/// long as a run lasts, and drops it the moment the run ends or the power
/// adapter is pulled.
@MainActor
final class UnattendedRun {
    static let shared = UnattendedRun()

    private init() {}

    #if os(macOS)
    /// The live activity token, or nil when none is held. `ProcessInfo`
    /// requires the very token it handed out to end the activity, and leaking
    /// one leaves the Mac awake for the rest of the app's life.
    private var token: (any NSObjectProtocol)?
    #endif

    /// What this device cannot promise about the run that is going, or nil
    /// when no run is going. Recomputed as the run loops, so unplugging a
    /// laptop mid-run changes what the user is told.
    private(set) var limit: UnattendedRunLimit?

    /// Called as a run starts and again on every pass of its loop, so a change
    /// of power source is picked up within one batch, and with `false` however
    /// the run ends.
    func update(isRunning: Bool) {
        #if os(macOS)
        let onPower = Self.isOnExternalPower
        setActivityHeld(isRunning && onPower)
        limit = isRunning ? (onPower ? .macSleepsAnyway : .macOnBattery) : nil
        #else
        limit = isRunning ? .deviceMayPauseWhenLocked : nil
        #endif
    }

    #if os(macOS)
    private func setActivityHeld(_ held: Bool) {
        switch (held, token) {
        case (true, nil):
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                // Surfaces verbatim in `pmset -g assertions`, and is the only
                // explanation the user gets there for a Mac that won't sleep.
                reason: "Analyzing photos for wallpaper"
            )
        case (false, let held?):
            ProcessInfo.processInfo.endActivity(held)
            token = nil
        default:
            break
        }
    }

    /// Whether the Mac is running off mains power. IOKit's power-source
    /// snapshot is the only public answer to this question on macOS; it is
    /// readable from the sandbox and reports `AC Power` on a desktop Mac,
    /// which has no battery to save.
    ///
    /// An unreadable snapshot answers "on power": the failure then costs a
    /// machine that stays awake through a run it would have finished anyway,
    /// rather than a long run that silently stops being unattended.
    private static var isOnExternalPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue()
        else { return true }
        return (source as String) == kIOPMACPowerKey
    }
    #endif
}
