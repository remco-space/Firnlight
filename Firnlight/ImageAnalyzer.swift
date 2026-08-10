import CoreGraphics
import Vision
import os

/// Runs the Vision pipeline on a single analysis bitmap.
///
/// Rejection order is cheapest-exit-first per the pipeline rules:
/// utility → people (a lot of people, or a prominent person) → not nature.
/// The feature print is generated only for images that survive all rejections.
///
/// People rule (FR-3.1): cityscapes admit distant figures, so a face only
/// rejects when it dominates the frame (height ≥ `personProminenceHeight`), when
/// there is a crowd (count ≥ `crowdFaceCount`), or when a confident human
/// rectangle is that prominent. Tiny background people no longer reject.
/// `nonisolated`: must run off the main actor inside the AnalysisQueue's task group.
nonisolated enum ImageAnalyzer {
    struct Outcome: Sendable {
        var isUtility = false
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
