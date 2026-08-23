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
/// Two label-based signals back the geometric ones, because a person can
/// defeat both detectors at once — a reclining subject's face stays under the
/// prominence bar while the body rectangle comes back at low confidence — yet
/// still dominate the scene: a `Thresholds.peopleLabels` label at high
/// confidence rejects on its own, and at moderate confidence rejects when a
/// prominence-sized human rectangle corroborates it. Both run on the
/// classification results the nature gate needs anyway, so they sit with it,
/// after the geometric exits.
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
        /// Tallest face or confident human rectangle, as a fraction of frame
        /// height (0 when the frame holds no detected person). Measured on
        /// the *same* detections the people gate above already ran — no extra
        /// Vision pass — and kept rather than collapsed into `hasPeople`,
        /// because a gate's yes/no answer is not the only thing a measurement
        /// is good for (FR-3.1, FR-5.2).
        var personProminence: Float?
        /// Area of the largest attention-salient region, as a fraction of the
        /// frame (0 when Vision finds no dominant subject — an evenly
        /// interesting field, which is itself a measurement and not a gap).
        var subjectProminence: Float?
        /// How centred that dominant salient region is: 1 when its centre sits
        /// at the frame's centre, 0 at the furthest corner.
        var subjectCentrality: Float?
        /// Mean relative luminance of the analysis bitmap, 0 (black) … 1
        /// (white) — how dark or bright the photo reads overall.
        var luminance: Float?
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
        outcome.personProminence = Self.personProminence(faces: faces, humans: humans)
        if humans.contains(where: {
            $0.confidence >= Thresholds.humanConfidenceThreshold
                && $0.boundingBox.height >= Thresholds.personProminenceHeight
        }) {
            outcome.hasPeople = true
            return outcome
        }

        // 2.5. People, by classification — the label-based signals described in
        // the type doc comment, on the same request the nature gate consumes.
        // Standalone: a high-confidence people label rejects on its own.
        // Corroborated: a moderate label plus a prominence-sized rectangle
        // (each too weak alone) rejects together.
        let labels = try await ClassifyImageRequest().perform(on: image)
        let personLabel = labels
            .filter { Thresholds.peopleLabels.contains($0.identifier.lowercased()) }
            .max { $0.confidence < $1.confidence }
        if let person = personLabel,
           person.confidence >= Thresholds.peopleLabelConfidenceThreshold
            || (person.confidence >= Thresholds.corroboratedPeopleLabelThreshold
                && humans.contains(where: {
                    $0.confidence >= Thresholds.corroboratedHumanConfidenceThreshold
                        && $0.boundingBox.height >= Thresholds.personProminenceHeight
                })) {
            outcome.hasPeople = true
            // Debug-level so both people-label thresholds can be tuned from real library data.
            log.debug("Rejected as people; label: \(person.identifier) \(person.confidence, format: .fixed(precision: 2))")
            return outcome
        }

        // 3. Nature — a scene label meets the confidence threshold on its own;
        // an object label (a flower, a plant) needs the classifier to have
        // seen `outdoor` too, or it reads as a still life — see
        // `Thresholds.natureObjectLabels`.
        let confident = labels.filter { $0.confidence >= Thresholds.natureConfidenceThreshold }
        let outdoorConfidence = labels
            .first { $0.identifier.lowercased() == "outdoor" }?.confidence ?? 0
        outcome.isNature = confident.contains { Thresholds.natureSceneLabels.contains($0.identifier.lowercased()) }
            || (outdoorConfidence >= Thresholds.outdoorCorroborationThreshold
                && confident.contains { Thresholds.natureObjectLabels.contains($0.identifier.lowercased()) })
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

        // 4. The quantified traits the ranker weighs — accepted images only,
        // for the same reason the feature print is: nothing here can change a
        // gate's answer, so measuring it before the gates have run would be
        // work spent on photos that are about to be set aside anyway.
        let featurePrint = try await GenerateImageFeaturePrintRequest().perform(on: image)
        outcome.featurePrint = featurePrint.data
        outcome.horizonAngleDegrees = try await measureHorizon(image)
        let saliency = try await GenerateAttentionBasedSaliencyImageRequest().perform(on: image)
        outcome.subjectProminence = Self.subjectProminence(saliency)
        outcome.subjectCentrality = Self.subjectCentrality(saliency)
        outcome.luminance = Self.meanLuminance(image)
        return outcome
    }

    /// Tallest detected person in the frame, as a fraction of frame height.
    ///
    /// Height rather than area, matching `Thresholds.personProminenceHeight`:
    /// the gate and the learned trait have to be reading the same quantity, or
    /// the band the gate admits would be measured on a different axis than the
    /// one that decided it was admissible. Faces and human rectangles are
    /// pooled by `max` because either can be the one that resolves — a face
    /// carries no confidence to filter on, while a body rectangle does, so
    /// only the latter is confidence-gated.
    private static func personProminence(
        faces: [FaceObservation],
        humans: [HumanObservation]
    ) -> Float {
        let faceHeight = faces.map(\.boundingBox.height).max() ?? 0
        let bodyHeight = humans
            .filter { $0.confidence >= Thresholds.humanConfidenceThreshold }
            .map(\.boundingBox.height)
            .max() ?? 0
        return Float(max(faceHeight, bodyHeight))
    }

    /// Fraction of the frame the largest attention-salient region covers.
    ///
    /// `salientObjects` rather than the heat map: the boxes are what Vision
    /// has already resolved into discrete regions, so reading them costs a
    /// property access, while reducing the heat map means walking a pixel
    /// buffer for a number the boxes already carry. An empty list is 0, not
    /// "unknown" — Vision ran and found no dominant subject, which is exactly
    /// what an even field of scenery looks like and is a legitimate value for
    /// the user's choices to weigh.
    private static func subjectProminence(_ saliency: SaliencyImageObservation) -> Float {
        let largest = saliency.salientObjects
            .map { $0.boundingBox.width * $0.boundingBox.height }
            .max() ?? 0
        return Float(min(1, max(0, largest)))
    }

    /// How centred the dominant salient region is: 1 at the frame's centre,
    /// 0 at the furthest corner. Normalized by the half-diagonal so the scale
    /// is fixed and library-independent, like every other trait the ranker
    /// weighs. Neutral (0.5) when there is no dominant subject to place —
/// nil when there is no dominant subject to place: unlike prominence,
    /// whose 0 is a real measurement ("no subject covers any of the frame"),
    /// the centre of nothing is not a value on this scale at all. FR-3.8's
    /// machinery is what that nil is for — the ranker substitutes the trait's
    /// own neutral and trains nothing on it, rather than this code inventing
    /// a number that would read as a measured half-off-centre subject.
    private static func subjectCentrality(_ saliency: SaliencyImageObservation) -> Float? {
        guard let dominant = saliency.salientObjects
            .max(by: { $0.boundingBox.width * $0.boundingBox.height
                     < $1.boundingBox.width * $1.boundingBox.height })
        else { return nil }
        let box = dominant.boundingBox
        let dx = box.origin.x + box.width / 2 - 0.5
        let dy = box.origin.y + box.height / 2 - 0.5
        let halfDiagonal = (0.5 * 0.5 + 0.5 * 0.5).squareRoot()
        return Float(max(0, 1 - (dx * dx + dy * dy).squareRoot() / halfDiagonal))
    }

    /// Mean relative luminance of the frame, 0 (black) … 1 (white).
    ///
    /// Drawn down to `luminanceSampleSize` square first: the mean of a
    /// box-filtered downsample is the mean of the full bitmap, and Core
    /// Graphics does that filtering in optimized code, so this costs a small
    /// blit instead of a walk over a megapixel. Grey colour space rather than
    /// averaging RGB by hand, so the channel weighting is the system's
    /// standard one rather than a constant this app would have to justify.
/// Returns nil only when the context cannot be created — a genuine
    /// "could not determine", which FR-3.8 requires be distinguishable from a
    /// measured value.
    ///
    /// `data: nil` lets Core Graphics own the backing store for as long as
    /// the context lives, rather than pointing the context at a Swift array's
    /// buffer: an array's memory is only guaranteed valid inside
    /// `withUnsafeMutableBytes`, so a context built on it and drawn into
    /// afterwards would be writing through a pointer the compiler is free to
    /// have invalidated.
    private static func meanLuminance(_ image: CGImage) -> Float? {
        let side = Thresholds.luminanceSampleSize
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        var total = 0
        for index in 0..<(side * side) { total += Int(pixels[index]) }
        return Float(total) / Float(side * side * 255)
    }

    /// Detected horizon tilt in degrees, or nil when no horizon is visible.
    static func measureHorizon(_ image: CGImage) async throws -> Float? {
        guard let observation = try await DetectHorizonRequest().perform(on: image) else { return nil }
        return Float(observation.angle.converted(to: .degrees).value)
    }
}
