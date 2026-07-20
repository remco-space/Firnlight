import Foundation
import SwiftData

/// One row per wallpaper candidate, keyed by the asset's PhotoKit identifier.
///
/// Records are created during the metadata scan (Phase 2) with analysis fields
/// at their defaults; the Vision pass (Phase 3) fills them in and stamps
/// `analysisVersion` so the pipeline can resume and re-run incrementally.
@Model
final class PhotoRecord {
    @Attribute(.unique) var localIdentifier: String
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?

    /// 0 = not yet analyzed. Compared against the current pipeline version.
    var analysisVersion: Int
    var isNature: Bool
    var hasPeople: Bool
    var isUtility: Bool
    var aestheticsScore: Float

    /// Raw Float array from GenerateImageFeaturePrintRequest; nil until analyzed.
    var featurePrint: Data?

    /// Denormalized cache of the ranker's raw (pre-sigmoid) score for this
    /// photo; nil until the ranker has scored it.
    var preferenceScore: Float?
    var analyzedAt: Date?

    /// True when analysis couldn't run (e.g. iCloud-only original with no local bitmap).
    var isSkipped: Bool = false

    /// Mirrors PHAsset.isFavorite; refreshed on every scan.
    var isFavorite: Bool = false

    /// User chose to fully ignore this photo (context menu "Ignore This
    /// Photo") — e.g. a fine photo that's emotionally triggering. Ignored
    /// photos leave the grid, duels, calibration, and album on next sync, and
    /// can be reviewed/un-ignored via the Library tab's "Show Ignored" filter.
    /// The stored attribute keeps its original name `isExcluded` so the meaning
    /// change needs no SwiftData migration. (This is distinct from "Not
    /// Wallpaper Material", which records a bad-quality VerdictRecord instead of
    /// excluding — see CandidateActions.)
    var isExcluded: Bool = false

    /// Detected horizon tilt in degrees (0 = level); nil when no horizon is
    /// visible (e.g. forest interiors) — treated as neutral, not penalized.
    var horizonAngleDegrees: Float?

    /// True once horizon detection ran, so the backfill pass can resume.
    var horizonMeasured: Bool = false

    init(localIdentifier: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, isFavorite: Bool) {
        self.localIdentifier = localIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.analysisVersion = 0
        self.isNature = false
        self.hasPeople = false
        self.isUtility = false
        self.aestheticsScore = 0
        self.featurePrint = nil
        self.preferenceScore = nil
        self.analyzedAt = nil
        self.isSkipped = false
        self.isFavorite = isFavorite
        self.isExcluded = false
    }
}
