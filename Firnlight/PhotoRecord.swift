import CoreLocation
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

    /// The same photo's identifier on *every* one of the user's devices, as
    /// `PHCloudIdentifier.archivalStringValue`; nil until the scan resolves it.
    ///
    /// `localIdentifier` is explicitly device-scoped — PhotoKit's own header
    /// says it "persistently identifies the object on a given device" — so it
    /// cannot key anything the user's judgments must survive being carried
    /// between devices (FR-9.1). Resolved in batches during the scan because
    /// the mapping call is documented as "very expensive"; see
    /// `LibraryScanner.resolveCloudIdentifiers`.
    var cloudIdentifier: String?

    /// What every judgment about this photo is filed under (FR-9.1, FR-9.2).
    ///
    /// The cloud identifier once known, the local one until then. The fallback
    /// is what makes the scheme total: a photo whose resolution failed is
    /// still judgeable, and its judgments are simply meaningless on other
    /// devices rather than lost — which is exactly how FR-9.2 already treats a
    /// photo that hasn't arrived. It also lets judgments be recorded before
    /// the first scan resolves anything; `LibraryScanner.rekeyJudgments` moves
    /// them onto the cloud key when it becomes available.
    var judgmentKey: String { cloudIdentifier ?? localIdentifier }

    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?

    /// `PHAsset.location`'s coordinate, split into two `Double?`s rather than
    /// stored as `CLLocation` because SwiftData attributes need a directly
    /// storable type; `CLLocation` isn't one. Nil together whenever the asset
    /// carries no location — most photos with Location Services off, or
    /// imported without EXIF GPS — which is the common case, not an error:
    /// `PreferenceRanker` treats the gap as neutral, never a penalty (FR-3.8),
    /// same as a photo with no visible horizon. Refreshed on every scan like
    /// `isFavorite`, since Photos lets the user assign or correct a location
    /// after the fact.
    var latitude: Double?
    var longitude: Double?

    /// 0 = not yet analyzed. Compared against the current pipeline version.
    var analysisVersion: Int
    var isNature: Bool
    var hasPeople: Bool
    var isUtility: Bool

    /// Severely blurred, smeared, or obstructed — a finger over the lens and
    /// the like (FR-3.1). Set only when `aestheticsScore` falls below
    /// `Thresholds.severelyFlawedAestheticsScore`; see `ImageAnalyzer`'s type
    /// doc comment. Added after `isNature`/`hasPeople`/`isUtility`, so it
    /// follows the later fields' pattern of an inline default rather than an
    /// init assignment — SwiftData's lightweight migration adds the column
    /// with that default for existing rows.
    var isFlawed: Bool = false

    var aestheticsScore: Float

    /// Raw Float array from GenerateImageFeaturePrintRequest; nil until analyzed.
    var featurePrint: Data?

    /// Denormalized cache of the ranker's raw (pre-sigmoid) score for this
    /// photo; nil until the ranker has scored it.
    var preferenceScore: Float?
    var analyzedAt: Date?

    /// True when the photo's pixels weren't available locally — an iCloud-only
    /// original with nothing on disk to analyze. Strictly a *deferral*: the
    /// retry pass downloads and analyzes these once the network allows it.
    ///
    /// Deliberately narrow. It used to also cover "Vision threw", which made
    /// the app tell the user that photos were waiting on iCloud when they were
    /// not — a diagnosis that is simply false, offered a retry that could never
    /// succeed, and triggered the "waiting for a network" message on a device
    /// with no iCloud account at all. Analysis failures now set
    /// `analysisFailed` instead (FR-3.2, FR-3.4).
    var isSkipped: Bool = false

    /// True when the pixels *were* available but the Vision request failed.
    ///
    /// Not retryable in the way `isSkipped` is: no amount of network will fix
    /// it, so these records are finished rather than deferred — they stop the
    /// pipeline claiming outstanding iCloud work, and stop the retry button
    /// promising something it cannot deliver (FR-3.5). Kept as its own flag
    /// rather than folded into a rejection reason because it is not a judgment
    /// about the photo: the app never got far enough to have one.
    var analysisFailed: Bool = false

    /// Mirrors PHAsset.isFavorite; refreshed on every scan.
    var isFavorite: Bool = false

    /// User chose to fully ignore this photo ("Ignore This Photo", from the
    /// thumbnail's own toggle, the context menu, or the menu bar) — e.g. a
    /// fine photo that's emotionally triggering. Ignored photos leave the
    /// grid, duels, calibration, and album on next sync, and can be reviewed
    /// and un-ignored via the Library tab's Ignored view (FR-4.9), where the
    /// same toggle reverses the decision (FR-4.6).
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

    init(localIdentifier: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, location: CLLocation?, isFavorite: Bool) {
        self.localIdentifier = localIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.latitude = location?.coordinate.latitude
        self.longitude = location?.coordinate.longitude
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
