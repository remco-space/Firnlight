import Vision

/// The runtime half of FR-5.2's "the app notices such changes itself —
/// including ones that arrive with a system update rather than with the
/// app". `Thresholds.currentAnalysisVersion` used to be a plain hand-bumped
/// constant: it caught a change to *this app's own* pipeline code (a new
/// rejection rule, a retuned threshold) because a developer bumped it when
/// making that change, but it could not catch Apple shipping a better face,
/// human, classification, aesthetics, smudge, horizon, or feature-print
/// model in a system update — the exact "arrive with a system update rather
/// than with the app" case the requirement calls out by name. This type
/// closes that gap by reading, at runtime, which revision each Vision
/// request `ImageAnalyzer` uses actually resolved to on *this* OS.
///
/// This works because every request type's `revision` (the concrete case an
/// unpinned `init(nil)` resolved to) and `supportedRevisions` (every case
/// the running system's Vision.framework currently knows about) are queried
/// from the installed system framework at call time, not baked into the
/// app binary at compile time — `Vision.framework` is a dynamically loaded
/// OS component, and Apple's own header comments describe the omitted-
/// revision initializer as picking "the latest revision available" on the
/// running system. A device that updates macOS/iOS and gets a newer default
/// revision for, say, `DetectFaceRectanglesRequest` reports that higher
/// revision here on its very next launch, with no Firnlight update
/// involved — verified against the installed 27 SDK's `Vision.swiftinterface`
/// (`sdk-capability-scan`): every request `ImageAnalyzer` calls exposes this
/// `Revision`/`supportedRevisions` pair (`GenerateImageFeaturePrintRequest`,
/// `CalculateImageAestheticsScoresRequest`, `DetectLensSmudgeRequest`,
/// `DetectFaceRectanglesRequest`, `DetectHumanRectanglesRequest`,
/// `ClassifyImageRequest`, `DetectHorizonRequest`).
///
/// Honest limit: this can only see revision *labels* changing. If Apple ever
/// updates the weights behind an existing revision case without minting a
/// new one, nothing here or anywhere else in the public API surface can see
/// that — there is no lower-level capability to fall back to, so that case
/// stays undetectable by design, not by oversight.
///
/// `nonisolated`: read from wherever `Thresholds.currentAnalysisVersion` is
/// read, off the main actor during analysis in particular.
nonisolated enum VisionRevisionFingerprint {
    /// Ordinal position of each request's resolved revision within that
    /// request's own `supportedRevisions`, one element per request
    /// `ImageAnalyzer` calls, in a fixed order. Position, not the revision
    /// case itself, because `Revision.hashValue` is process-randomized
    /// (unusable across launches) and the case carries no public raw value
    /// — but `supportedRevisions` is itself queried from the running
    /// framework, so its indices are exactly as fresh as the revision they
    /// index.
    private static func ordinals() -> [Int] {
        func ordinal<R: Equatable>(_ revision: R, in supported: [R]) -> Int {
            supported.firstIndex(of: revision) ?? 0
        }
        return [
            ordinal(DetectFaceRectanglesRequest().revision, in: DetectFaceRectanglesRequest.supportedRevisions),
            ordinal(DetectHumanRectanglesRequest().revision, in: DetectHumanRectanglesRequest.supportedRevisions),
            ordinal(ClassifyImageRequest().revision, in: ClassifyImageRequest.supportedRevisions),
            ordinal(CalculateImageAestheticsScoresRequest().revision, in: CalculateImageAestheticsScoresRequest.supportedRevisions),
            ordinal(DetectLensSmudgeRequest().revision, in: DetectLensSmudgeRequest.supportedRevisions),
            ordinal(DetectHorizonRequest().revision, in: DetectHorizonRequest.supportedRevisions),
            ordinal(GenerateImageFeaturePrintRequest().revision, in: GenerateImageFeaturePrintRequest.supportedRevisions),
        ]
    }

    /// The above, packed into one non-negative `Int`: each ordinal gets 4
    /// bits (room for 16 revisions per request — Vision has never shipped
    /// more than 4 for any request this app uses, so this has triple the
    /// headroom it has ever needed), concatenated in the fixed order above.
    /// Any single request resolving to a later revision strictly increases
    /// this value, which is exactly the "behind" test
    /// `AnalysisGeneration`/`AnalysisQueue` already do with `<` on
    /// `PhotoRecord.analysisVersion` — no change to that comparison, or to
    /// the column's type, is needed.
    ///
    /// A resilient system framework can only grow `supportedRevisions`
    /// across an OS update, in either declared order or (per Apple's own
    /// convention observed across every request scanned above) chronological
    /// order matching the case names — so this only ever moves in the
    /// direction a re-examination is worth doing, never backwards on the
    /// same OS.
    ///
    /// Cached once per process: a running process has already mapped one
    /// version of `Vision.framework`, so this cannot change mid-run — an OS
    /// update that changes it only takes effect on the app's next launch,
    /// which is exactly when this is next read.
    static let packed: Int = ordinals().reduce(0) { ($0 << 4) | min($1, 15) }
}
