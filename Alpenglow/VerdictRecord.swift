import Foundation
import SwiftData

/// An absolute quality verdict from the duel's "Both Are Great" / "Both Are
/// Bad" buttons. Unlike ChoiceRecord (relative preference), verdicts anchor
/// where the wallpaper-worthiness bar sits on the score scale — used to
/// calibrate the suggested album size.
@Model
final class VerdictRecord {
    var localIdentifier: String
    var isGood: Bool
    var timestamp: Date

    init(localIdentifier: String, isGood: Bool, timestamp: Date) {
        self.localIdentifier = localIdentifier
        self.isGood = isGood
        self.timestamp = timestamp
    }
}

/// Shared verdict-split logic used by both the ranker's duel-pool bar and the
/// album-size calibration, so the two stay in lock-step.
nonisolated enum VerdictCalibration {
    /// Latest verdict per photo wins; expects `verdicts` in timestamp order.
    static func latestByPhoto(_ verdicts: [VerdictRecord]) -> [String: Bool] {
        var latest: [String: Bool] = [:]
        for verdict in verdicts { latest[verdict.localIdentifier] = verdict.isGood }
        return latest
    }

    /// Optimal 1-D split: minimize (goods ≤ t) + (bads > t). The ascending scan
    /// means ties resolve to the higher (stricter) threshold. Scale-free.
    static func optimalSplitThreshold(good: [Float], bad: [Float]) -> Float {
        var bestThreshold = bad.max() ?? 0
        var bestErrors = Int.max
        for threshold in (good + bad).sorted() {
            let errors = good.count(where: { $0 <= threshold }) + bad.count(where: { $0 > threshold })
            if errors <= bestErrors {
                bestErrors = errors
                bestThreshold = threshold
            }
        }
        return bestThreshold
    }
}
