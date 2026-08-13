import Foundation
import SwiftData
import os

/// Which generation of analysis every ranking-affecting query compares photos
/// within — FR-5.2's "equal terms", and specifically its second half, "equal
/// terms cuts both ways".
///
/// `Thresholds.currentAnalysisVersion` is what *this build's* Vision pipeline
/// produces and what `AnalysisQueue` re-examines the library up to in the
/// background. It is deliberately NOT what the ranker, grid, duels, verdict
/// calibration and album filter on. Those filtered on it directly until this
/// type existed, which made the version bump itself the outage FR-5.2 forbids:
/// the instant a build shipped with a higher version, every record still
/// carrying the previous one became ineligible everywhere at once, and the
/// user's grid, duels and album emptied until a re-examination measured in
/// hours on a large library caught up. FR-5.2 asks for the opposite — "a
/// change in the app's understanding never empties what the user sees — the
/// app keeps serving the best picture its previous understanding supports
/// until the new understanding is at least as complete, and every part of the
/// app hands over together."
///
/// So the serving generation is simply **whichever generation currently
/// supports the most candidates**, with the current one winning ties:
///
/// - Nothing behind (the ordinary case, and every fresh install): the current
///   generation, immediately. "A change that doesn't alter how photos are
///   examined re-examines nothing: already-current analysis stays current" —
///   nothing here fires unless `Thresholds.currentAnalysisVersion` actually
///   moves, which per that constant's own doc comment only happens when the
///   pipeline genuinely changed. A no-op change leaves every record already
///   at the current version, this returns it on the first branch, and not one
///   photo is re-examined or set aside.
/// - Mid-re-examination: records move from the old generation to the new one
///   in place, so the old cohort shrinks by exactly what the new one gains.
///   Serving the larger of the two is therefore both "the best picture its
///   previous understanding supports" *and* a handover at precisely the
///   moment "the new understanding is at least as complete" — the crossover.
///   The visible set dips to at worst half the library and never to nothing,
///   which is the best any in-place re-examination can do without keeping two
///   full analyses of every photo on disk.
///
/// Waiting instead for the old generation to empty out — the obvious reading
/// of "until the new understanding is at least as complete" — is the one
/// thing that must not be done: the old cohort empties *because* its records
/// are being re-examined, so serving it to the end walks the grid down to a
/// single photo and then flips it back to full. That is the forbidden
/// emptying, arrived at slowly.
///
/// Generations *ahead* of the current one (a downgrade, or a store touched by
/// a newer build) are ignored rather than served: `AnalysisQueue` only
/// re-examines records behind the current version, so a cohort ahead of it
/// would never be reconciled and this would never hand back. Those records
/// sit out until a build that understands them comes along, exactly as any
/// out-of-generation record does.
///
/// Derived from the store on every read rather than cached anywhere. That is
/// what makes "every part of the app hands over together" true by
/// construction: the ranker, the grid, the verdict calibration and the album
/// all ask the same question of the same rows and get the same answer, with
/// no stored generation to drift out of step with them or to have to be
/// migrated when this shipped.
///
/// `AnalysisQueue` deliberately does not go through this: its pending-work
/// queries and its statistics target `Thresholds.currentAnalysisVersion`
/// directly. It is the mechanism that closes the gap, not a consumer of the
/// protection.
nonisolated enum AnalysisGeneration {
    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "AnalysisGeneration")

    /// The analysis version that ranking-affecting queries should restrict
    /// themselves to right now. Pure read; nothing is written or remembered.
    static func servingVersion(in context: ModelContext) -> Int {
        let current = Thresholds.currentAnalysisVersion

        // Only candidates count: what FR-5.2 protects is what the user sees,
        // and a record that is not a candidate (not nature, ignored, still
        // unanalyzed at version 0) is in no generation's picture.
        let behindCount = (try? context.fetchCount(FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion < current }
        ))) ?? 0
        guard behindCount > 0 else { return current }

        let currentCount = (try? context.fetchCount(FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion == current }
        ))) ?? 0
        // Any single older generation is at most the whole behind set, so this
        // settles it without the grouping fetch below — the fast path, and the
        // only one taken once a re-examination is past its halfway point.
        guard currentCount < behindCount else { return current }

        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion < current }
        )
        // Only the one column is needed to count cohorts; the rest of the row
        // stays unfaulted (FR-8.2 — this runs inside every ranked query).
        descriptor.propertiesToFetch = [\.analysisVersion]
        guard let behind = try? context.fetch(descriptor) else { return current }

        var sizeByVersion: [Int: Int] = [:]
        for record in behind {
            sizeByVersion[record.analysisVersion, default: 0] += 1
        }
        // Strictly greater, so the current generation takes ties and the
        // handover happens the moment it is *at least* as complete. Among
        // older cohorts of equal size the later one wins, so the app never
        // steps further back than it has to.
        guard let best = sizeByVersion
            .filter({ $0.value > currentCount })
            .max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { return current }
        // Rare and bounded — only while a re-examination is under way — and
        // the one state in which the app is deliberately showing less than
        // the library holds, so it is worth being able to see in the log.
        log.info("Serving analysis generation \(best.key) (\(best.value) candidates) over \(current) (\(currentCount)) until the re-examination catches up")
        return best.key
    }
}
