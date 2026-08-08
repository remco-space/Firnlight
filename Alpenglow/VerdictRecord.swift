import Foundation
import SwiftData

/// An absolute quality verdict from the duel's "Both Are Great" / "Both Are
/// Bad" buttons. Unlike ChoiceRecord (relative preference), verdicts anchor
/// where the wallpaper-worthiness bar sits on the score scale — used to
/// calibrate the suggested album size.
///
/// Keyed by `PhotoRecord.judgmentKey` and stored beside the other judgments —
/// see `ChoiceRecord` for why the column keeps its old name and why the shape
/// is what it is.
@Model
final class VerdictRecord {
    @Attribute(originalName: "localIdentifier") var photoKey: String = ""
    var isGood: Bool = false
    var timestamp: Date = Date.distantPast
    /// A clearing record: FR-4.6's "Not Wallpaper Material" toggle un-marking
    /// a photo, or FR-4.7's "return to normal standing" more generally. The
    /// ledger stays append-only and last-timestamp-wins, exactly like
    /// `IgnoreRecord` — see its doc comment for why a toggle has to resolve
    /// this way rather than by deleting the row it undoes: two devices
    /// toggling the same photo apart must resolve to whichever the user did
    /// last, not to whichever synced last, and only an added row (never a
    /// delete racing a sync) can express that. Defaulted like every other
    /// attribute here so the shape stays CloudKit-mirrorable the same way.
    var isCleared: Bool = false

    init(photoKey: String, isGood: Bool, isCleared: Bool = false, timestamp: Date) {
        self.photoKey = photoKey
        self.isGood = isGood
        self.isCleared = isCleared
        self.timestamp = timestamp
    }
}

/// Shared verdict-split logic used by both the ranker's duel-pool bar and the
/// album-size calibration, so the two stay in lock-step.
nonisolated enum VerdictCalibration {
    /// Latest verdict per photo wins; expects `verdicts` in timestamp order.
    /// Keyed by `PhotoRecord.judgmentKey`, so a verdict recorded on another
    /// device lands on the same photo here (FR-9.1). A clearing record
    /// (`isCleared`) REMOVES the photo's entry rather than writing `false`
    /// into it: FR-4.7 says clearing returns the photo to normal standing
    /// "as if it had never been marked", so a cleared photo must contribute
    /// to neither the good nor the bad side of anything reading this map
    /// (the album-size calibration, the verdict bar) — not count as good,
    /// which it never claimed to be either.
    static func latestByPhoto(_ verdicts: [VerdictRecord]) -> [String: Bool] {
        var latest: [String: Bool] = [:]
        for verdict in verdicts {
            if verdict.isCleared {
                latest[verdict.photoKey] = nil
            } else {
                latest[verdict.photoKey] = verdict.isGood
            }
        }
        return latest
    }

    /// Which bad verdicts should train the ranker, given `verdicts` in
    /// ascending timestamp order: a bad verdict trains unless a *later*
    /// clearing record exists for the same photo. Good verdicts are ignored
    /// here — they never train, per `PreferenceRanker`'s file-level doc
    /// comment — so this only ever returns a subset of the bad verdicts,
    /// never anything for a cleared-then-not-yet-re-marked photo.
    ///
    /// Implementation walks the ledger once, accumulating bad verdicts per
    /// photo key; a clearing record for a photo drops everything accumulated
    /// for it so far. That mirrors the only tool available to undo an SGD
    /// step: SGD has no inverse, so the sole way to un-train a bad verdict is
    /// to leave it out of the replay entirely — this function decides which
    /// verdicts get left out. Re-marking a photo bad after a clear appends a
    /// new `VerdictRecord`, which accumulates again and DOES train, so the
    /// incremental path (`PreferenceRanker.recordVerdicts`, one SGD step per
    /// call) and this replay path always agree on how many bad verdicts are
    /// "live" for a photo at any point in the ledger.
    static func trainingBadVerdicts(_ verdicts: [VerdictRecord]) -> [VerdictRecord] {
        var accumulated: [String: [VerdictRecord]] = [:]
        for verdict in verdicts {
            if verdict.isCleared {
                accumulated[verdict.photoKey] = nil
            } else if !verdict.isGood {
                accumulated[verdict.photoKey, default: []].append(verdict)
            }
        }
        return accumulated.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
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
