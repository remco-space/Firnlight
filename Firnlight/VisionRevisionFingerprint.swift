import Foundation
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
/// unpinned `init(nil)` resolved to) is queried from the installed system
/// framework at call time, not baked into the app binary at compile time —
/// `Vision.framework` is a dynamically loaded OS component, and Apple's own
/// header comments describe the omitted-revision initializer as picking "the
/// latest revision available" on the running system. A device that updates
/// macOS/iOS and gets a newer default revision for, say,
/// `DetectFaceRectanglesRequest` reports that as a *different* fingerprint
/// here on its very next launch, with no Firnlight update involved —
/// verified against the installed 27 SDK's `Vision.swiftinterface`
/// (`sdk-capability-scan`): every request `ImageAnalyzer` calls exposes this
/// `revision` property (`GenerateImageFeaturePrintRequest`,
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
    /// Stable text naming which revision each Vision request `ImageAnalyzer`
    /// uses currently resolves to, one entry per request in a fixed order,
    /// joined into one string. Deliberately equality-only: earlier drafts of
    /// this type tried to *rank* revisions against each other (an ordinal
    /// position within `supportedRevisions`, packed so a "later" revision
    /// produced a strictly greater number) and that ranking broke two ways —
    /// a resolved revision `firstIndex(of:)` couldn't find in
    /// `supportedRevisions` silently fell back to ordinal 0, reporting a
    /// genuine change as none, and nothing about `supportedRevisions`
    /// actually documents that its ordering is ascending or append-only, so
    /// even a correctly found ordinal could move the "wrong" way on some
    /// future OS. Naming the revision Vision itself resolved to needs no
    /// such assumption: `String(describing:)` on a plain, case-only enum
    /// (every `Revision` type used here) yields the case's own name
    /// (`"revision4"`), which is stable across launches — unlike
    /// `Revision.hashValue`, process-randomized and unusable for this — and
    /// changes if and only if the resolved case actually changes.
    static var current: String {
        [
            "face:\(DetectFaceRectanglesRequest().revision)",
            "human:\(DetectHumanRectanglesRequest().revision)",
            "classify:\(ClassifyImageRequest().revision)",
            "aesthetics:\(CalculateImageAestheticsScoresRequest().revision)",
            "smudge:\(DetectLensSmudgeRequest().revision)",
            "horizon:\(DetectHorizonRequest().revision)",
            "featurePrint:\(GenerateImageFeaturePrintRequest().revision)",
        ].joined(separator: "|")
    }

    private static let baselineDefaultsKey = "space.remco.Firnlight.visionRevisionFingerprint.baseline"
    private static let generationDefaultsKey = "space.remco.Firnlight.visionRevisionFingerprint.generation"

    /// How many times `current` has been observed to differ from the
    /// previous launch's baseline, on this device, persisted in
    /// `UserDefaults` (matching how the rest of the app keeps per-device
    /// state — `WallpaperExporter`, `ExportModel`, `UpdateCheck` — analysis
    /// is itself per-device today; see REQUIREMENTS.md's "Parked" section on
    /// the iCloud transport). Monotonically non-decreasing: once bumped, it
    /// never falls back, so records re-examined under a bumped generation
    /// never look "ahead" of a later launch that happens to observe the same
    /// fingerprint again — the same reasoning `AnalysisGeneration`'s own doc
    /// comment gives for never serving a generation backwards.
    ///
    /// The very first read on a device — no stored baseline yet, whether a
    /// fresh install or the first launch of the build that introduced this
    /// type — adopts whatever is currently resolved as the baseline and
    /// reports generation 0, rather than comparing against absence. There is
    /// no historical fingerprint on record for photos this device already
    /// analyzed under the plain hand-tuned version scheme that predates this
    /// type, and treating "nothing on record" as "a change happened" would
    /// be exactly the bug this guards against in reverse: it would queue an
    /// upgrading device's entire library for re-examination for a reason
    /// that never happened, the day this code first ships, on every device
    /// whose Vision revisions hadn't moved at all. Assuming continuity is
    /// the only reading consistent with FR-5.2's "a change that doesn't
    /// alter how photos are examined re-examines nothing: already-current
    /// analysis stays current" — encoding a fingerprint for the first time
    /// is not itself such a change.
    ///
    /// Cached once per process (`static let`, not a computed `var`): `current`
    /// cannot change mid-run — a running process has already mapped one
    /// version of `Vision.framework`, so an OS update that changes it only
    /// takes effect on the app's next launch — and `AnalysisGeneration`'s own
    /// doc comment notes it runs "inside every ranked query", so this avoids
    /// re-touching `UserDefaults` on every one of those reads.
    static let generation: Int = {
        let defaults = UserDefaults.standard
        let observed = current
        guard let baseline = defaults.string(forKey: baselineDefaultsKey) else {
            defaults.set(observed, forKey: baselineDefaultsKey)
            defaults.set(0, forKey: generationDefaultsKey)
            return 0
        }
        guard baseline != observed else {
            return defaults.integer(forKey: generationDefaultsKey)
        }
        let next = defaults.integer(forKey: generationDefaultsKey) + 1
        defaults.set(observed, forKey: baselineDefaultsKey)
        defaults.set(next, forKey: generationDefaultsKey)
        return next
    }()
}
