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

    /// Denormalized cache of the ranker's current score for this photo.
    var preferenceScore: Float
    var analyzedAt: Date?

    /// True when analysis couldn't run (e.g. iCloud-only original with no local bitmap).
    var isSkipped: Bool = false

    /// Mirrors PHAsset.isFavorite; refreshed on every scan.
    var isFavorite: Bool = false

    /// User marked this photo as never wallpaper-suitable (context menu).
    /// Excluded photos leave the grid, duels, and album on next sync.
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
        self.preferenceScore = 0
        self.analyzedAt = nil
        self.isSkipped = false
        self.isFavorite = isFavorite
        self.isExcluded = false
    }
}
