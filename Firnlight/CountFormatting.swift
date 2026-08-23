import Foundation

/// FR-8.1's HIG deference, for the one thing the HIG asks of every
/// count-bearing sentence in the app: locale-correct digit grouping, and
/// grammatical agreement between a count and the noun it quantifies ("1
/// photo", never "1 photos").
///
/// A hand-written singular/plural branch, not a String Catalog plural
/// variation: REQUIREMENTS.md's parked list is explicit that "the app is
/// English throughout, and nothing is designed to be translated", so there is
/// no `.xcstrings` catalog backing this app's copy for ICU plural rules to
/// hang off. This is the deliberate substitute for that infrastructure, not
/// an omission of it — one place, so every call site gets both halves (the
/// grouping and the agreement) together rather than a call site fixing one
/// and forgetting the other, which is exactly how this bug shipped the first
/// time (FR-8.1 review, 2026-08-23).
extension Int {
    /// "N noun" or "N nouns", with `self` locale-grouped either way. `plural`
    /// defaults to `singular + "s"`, which covers every noun this app counts
    /// (photo, candidate, near-duplicate); pass it explicitly for an
    /// irregular one if that ever changes.
    func counted(_ singular: String, _ plural: String? = nil) -> String {
        "\(formatted()) \(self == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// Just the noun half of `counted(_:_:)`, for a sentence that already
    /// wrote the number itself (e.g. as its own `.formatted()` interpolation)
    /// and only needs the matching singular/plural word.
    func agreeing(_ singular: String, _ plural: String? = nil) -> String {
        self == 1 ? singular : (plural ?? singular + "s")
    }
}
