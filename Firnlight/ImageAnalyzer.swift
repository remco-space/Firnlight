import CoreGraphics
import Vision
import os

/// Runs the Vision pipeline on a single analysis bitmap.
///
/// Rejection order is cheapest-exit-first per the pipeline rules:
/// utility → flawed (blur/smear/obstruction) → people (a lot of people, or a
/// prominent person) → not nature. The feature print is generated only for
/// images that survive all rejections.
///
/// People rule (FR-3.1): cityscapes admit distant figures, so a face only
/// rejects when it dominates the frame (height ≥ `personProminenceHeight`), when
/// there is a crowd (count ≥ `crowdFaceCount`), or when a confident human
/// rectangle is that prominent. Tiny background people no longer reject.
///
/// Flaw rule (FR-3.1): two independent signals gate this, either sufficient on
/// its own. `CalculateImageAestheticsScoresRequest`'s `overallScore` is
/// documented by Apple to fold in "how well taken" the image is — blur and
/// exposure among its factors — distinct from `isUtility`, which is about
/// content type (screenshots, documents), not technical quality. A score
/// below `Thresholds.severelyFlawedAestheticsScore` is treated as the
/// technical flaw FR-3.1 names. Separately, `DetectLensSmudgeRequest`
/// (macOS/iOS 26+) is Vision's dedicated detector for exactly the flaw FR-3.1
/// names first — "a finger over the lens" — and catches a smudge an otherwise
/// well-exposed, sharp frame's aesthetics score alone would miss. Either gate
/// rejects the photo before it is ever scored for nature content — "however
/// good the scene" in the requirement's own words.
/// `nonisolated`: must run off the main actor inside the AnalysisQueue's task group.
nonisolated enum ImageAnalyzer {
    struct Outcome: Sendable {
        var isUtility = false
        var isFlawed = false
        var hasPeople = false
        var isNature = false
        var aestheticsScore: Float = 0
        var featurePrint: Data?
        var horizonAngleDegrees: Float?
    }

    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "ImageAnalyzer")

    static func analyze(_ image: CGImage) async throws -> Outcome {
        var outcome = Outcome()

        // 1. Aesthetics — score is kept either way; utility images exit early.
        let aesthetics = try await CalculateImageAestheticsScoresRequest().perform(on: image)
        outcome.aestheticsScore = aesthetics.overallScore
        outcome.isUtility = aesthetics.isUtility
        if outcome.isUtility { return outcome }

        // 1.5. Flawed — a badly blurred, smeared, or obstructed frame, however
        // good the scene would otherwise be (FR-3.1). Two independent gates;
        // see the type doc comment for why neither alone is redundant.
        if outcome.aestheticsScore < Thresholds.severelyFlawedAestheticsScore {
            outcome.isFlawed = true
            // Debug-level so severelyFlawedAestheticsScore can be tuned from real library data.
            log.debug("Rejected as flawed; overallScore: \(outcome.aestheticsScore, format: .fixed(precision: 2))")
            return outcome
        }
        let smudge = try await DetectLensSmudgeRequest().perform(on: image)
        if smudge.confidence >= Thresholds.lensSmudgeConfidenceThreshold {
            outcome.isFlawed = true
            // Debug-level so lensSmudgeConfidenceThreshold can be tuned from real library data.
            log.debug("Rejected as flawed; lens smudge confidence: \(smudge.confidence, format: .fixed(precision: 2))")
            return outcome
        }

        // 2. People — a crowd, a frame-dominating face, or a prominent confident
        // human rectangle. Distant tiny figures in a cityscape are allowed.
        let faces = try await DetectFaceRectanglesRequest().perform(on: image)
        if faces.count >= Thresholds.crowdFaceCount
            || faces.contains(where: { $0.boundingBox.height >= Thresholds.personProminenceHeight }) {
            outcome.hasPeople = true
            return outcome
        }
        let humans = try await DetectHumanRectanglesRequest().perform(on: image)
        if humans.contains(where: {
            $0.confidence >= Thresholds.humanConfidenceThreshold
                && $0.boundingBox.height >= Thresholds.personProminenceHeight
        }) {
            outcome.hasPeople = true
            return outcome
        }

        // 3. Nature — any allowlisted label meeting the confidence threshold.
        let labels = try await ClassifyImageRequest().perform(on: image)
        let confident = labels.filter { $0.confidence >= Thresholds.natureConfidenceThreshold }
        outcome.isNature = confident.contains { Thresholds.natureLabels.contains($0.identifier.lowercased()) }
        guard outcome.isNature else {
            // Debug-level so the allowlist can be tuned from real library data.
            let rejected = (confident.isEmpty
                ? Array(labels.sorted { $0.confidence > $1.confidence }.prefix(3))
                : confident)
                .map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }
                .joined(separator: ", ")
            log.debug("Rejected as not-nature; labels: \(rejected)")
            return outcome
        }

        // 4. Feature print + horizon for the ranker — accepted images only.
        let featurePrint = try await GenerateImageFeaturePrintRequest().perform(on: image)
        outcome.featurePrint = featurePrint.data
        outcome.horizonAngleDegrees = try await measureHorizon(image)
        return outcome
    }

    /// Detected horizon tilt in degrees, or nil when no horizon is visible.
    static func measureHorizon(_ image: CGImage) async throws -> Float? {
        guard let observation = try await DetectHorizonRequest().perform(on: image) else { return nil }
        return Float(observation.angle.converted(to: .degrees).value)
    }
}
