import SwiftUI

extension View {
    /// Marks this view as a transient wait indicator — a spinner, a "loading…"
    /// placeholder — and makes it behave the way FR-8.7 requires.
    ///
    /// Two things follow from that requirement, and this modifier is where both
    /// are implemented so no call site has to remember either:
    ///
    /// - **It holds its place.** The indicator is hidden with `opacity`, never
    ///   by being left out of the view tree. Space for it is reserved whether
    ///   or not it is showing, so a picker, a button, or a count sitting beside
    ///   it does not slide sideways the moment work starts or stops. Call sites
    ///   therefore build the indicator *unconditionally* and pass the state in
    ///   here, rather than wrapping it in an `if`.
    /// - **It only shows up for a wait worth reporting.** Nothing appears until
    ///   the work has been running for `Thresholds.noticeableWaitDelay`; work
    ///   that beats that finishes without the user ever seeing a spinner. Most
    ///   of this app's reloads (a SwiftData count, a cached thumbnail,
    ///   recording one duel choice) do beat it, and a spinner that appears and
    ///   vanishes inside a frame or two reads as a glitch rather than as
    ///   progress.
    ///
    /// Hidden means hidden to VoiceOver too: an indicator that is not on screen
    /// must not be announced, or the "silent" case would be silent only
    /// visually.
    ///
    /// - Parameter isWaiting: whether the work is still running. Defaults to
    ///   `true` for the common case where the indicator is *itself* one branch
    ///   of a content swap and only exists while the wait does — there the
    ///   delay clause is what matters and the reservation is moot, because the
    ///   content that replaces it changes the layout anyway.
    func shownWhileWaiting(_ isWaiting: Bool = true) -> some View {
        modifier(ShownWhileWaiting(isWaiting: isWaiting))
    }
}

private struct ShownWhileWaiting: ViewModifier {
    let isWaiting: Bool
    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .opacity(isShowing ? 1 : 0)
            .accessibilityHidden(!isShowing)
            .animation(.default, value: isShowing)
            // `.task(id:)`, not `onChange` plus a timer: SwiftUI cancels and
            // restarts it on every flip of `isWaiting` and tears it down when
            // the view goes away, which is exactly the lifetime the delay
            // needs. A wait that ends before the sleep elapses cancels it, and
            // the cancellation check below is what keeps the spinner from
            // flashing on afterwards.
            .task(id: isWaiting) {
                guard isWaiting else {
                    isShowing = false
                    return
                }
                try? await Task.sleep(for: Thresholds.noticeableWaitDelay)
                guard !Task.isCancelled else { return }
                isShowing = true
            }
    }
}
