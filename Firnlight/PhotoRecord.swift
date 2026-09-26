import CoreLocation
import Foundation
import Photos
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
    /// after the fact. Both are stored even though `PreferenceRanker`
    /// currently only learns from `latitude` (see the doc comment on
    /// `PreferenceRanker.Entry.location` for why longitude isn't a
    /// fixed-scale linear feature the same way — it wraps at the
    /// antimeridian); the full coordinate is what FR-5.2 asks the app to
    /// observe, and keeping it costs nothing.
    var latitude: Double?
    var longitude: Double?

    /// FR-5.14's four-scale place hierarchy, resolved offline from
    /// `latitude`/`longitude` via `PlaceHierarchy.offlineKeys` and cached
    /// here rather than recomputed on every ranker reload — a
    /// point-in-polygon/nearest-point search over the whole gazetteer for
    /// every candidate on every duel would cost real time (FR-8.2) for a
    /// coordinate that essentially never changes. `LibraryScanner` computes
    /// these whenever it (re)assigns `latitude`/`longitude`, the same
    /// re-sync-on-change treatment `cameraHeading` and the rest already get,
    /// and also whenever `PlaceGazetteer.dataFingerprint` no longer matches
    /// the fingerprint the last scan resolved against (the gazetteer's own
    /// data changed underneath an unchanged coordinate).
    /// `gazetteerLandscape` is FR-5.14's natural scale ("a landscape or
    /// mountain range... known down to the landscapes people name
    /// locally") and `gazetteerRegion` is its political counterpart — both
    /// always independently resolved, never one standing in for the other
    /// ("the natural and the political alike"). Independently nil where the
    /// gazetteer has no answer at that scale — see `PlaceGazetteer`'s doc
    /// comment — which `gazetteerResolved` tells apart from "not computed
    /// yet" (a record that predates this field, or one with no location at
    /// all).
    var gazetteerTown: String?
    var gazetteerLandscape: String?
    var gazetteerRegion: String?
    var gazetteerCountry: String?
    /// True once the four fields above have been computed for this
    /// record's current `latitude`/`longitude` against the gazetteer data's
    /// current `PlaceGazetteer.dataFingerprint` (even if all four came back
    /// nil) — distinguishes "the gazetteer genuinely has nothing here" from
    /// "this record predates the field, or the gazetteer data has since
    /// changed, and hasn't been looked at yet", which a plain nil check on
    /// the four fields above cannot.
    var gazetteerResolved: Bool = false

    /// FR-5.14's fifth scale — "where the network allows, the app also
    /// learns what Apple's maps call the place... and that name counts as
    /// one more of the places the photo is known by." Composed by
    /// `PlaceHierarchy.networkPlaceKey` from `MKAddressRepresentations
    /// .cityName`/`.regionName` (see `PlaceNameLookup`) and cached here the
    /// same way the four offline fields above are, so ranking never re-reads
    /// `PlaceNameRecord`'s per-grid-cell cache on every reload — `PlaceNameLookup
    /// .resolveNext()` writes this onto every `PhotoRecord` sharing the
    /// resolved spot's grid cell once it resolves. Nil until resolved, or if
    /// Apple genuinely had no name for this spot; `networkPlaceResolved`
    /// tells the two apart the same way `gazetteerResolved` does for the
    /// offline fields. Deliberately never merged with any `gazetteer*`
    /// field above — see `PlaceHierarchy`'s doc comment for why conflating
    /// an offline scale with a network answer is exactly the leak FR-5.14's
    /// "never reaches another" forbids.
    var networkPlaceName: String?
    var networkPlaceResolved: Bool = false

    /// Metres above sea level, from the same `CLLocation` latitude and
    /// longitude come from.
    ///
    /// Read without consulting `verticalAccuracy`, which Photos leaves at 0
    /// on every asset in a real library even where the altitude itself is
    /// exact — checking it, as the conventional CoreLocation idiom says to,
    /// discards the whole trait. Verified against the originals' EXIF
    /// `GPSAltitude`: identical to full precision.
    var altitude: Double?

    /// Degrees clockwise from true north that the camera was pointing.
    ///
    /// `CLLocation.course`, which for a photo is not the direction of travel
    /// — it is populated on photos taken standing still, and matches the
    /// originals' EXIF `GPSDestBearing` exactly. (EXIF `GPSImgDirection`
    /// agrees except on front-camera shots, where it is the same bearing
    /// turned 180°; those are portraits and never reach the candidate set.)
    /// Taken from `CLLocation` rather than EXIF deliberately: reading EXIF
    /// would mean pulling every original down from iCloud, which FR-5.13
    /// forbids a derived trait from causing.
    var cameraHeading: Double?

    /// `PHAssetMediaSubtype`'s raw bits, stored whole rather than as the one
    /// flag the scanner filters on: panorama, HDR, depth-effect and
    /// live-photo are all things the app knows about a photo, and a gate's
    /// yes/no answer is not the only use for them (FR-3.1, FR-5.2).
    var mediaSubtypes: Int?

    // The stored bits read back through Photos' own named flags rather than
    // hand-copied bit positions — an earlier revision copied them by hand and
    // got depth-effect and screenshot the wrong way round, since they are
    // adjacent bits and both plausible. Nil when the record predates the
    // field, which keeps it an honest gap rather than four false negatives.
    private var subtypeFlags: PHAssetMediaSubtype? {
        mediaSubtypes.map { PHAssetMediaSubtype(rawValue: UInt(bitPattern: $0)) }
    }

    var isPanorama: Bool? { subtypeFlags?.contains(.photoPanorama) }
    var isHDR: Bool? { subtypeFlags?.contains(.photoHDR) }
    var isDepthEffect: Bool? { subtypeFlags?.contains(.photoDepthEffect) }
    var isLivePhoto: Bool? { subtypeFlags?.contains(.photoLive) }

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

    // MARK: Quantified traits the ranker weighs (FR-5.2)
    //
    // Each is what `ImageAnalyzer` measured, stored raw and on its own fixed,
    // library-independent scale — never normalized against the rest of the
    // library, which would silently rescale every trained weight the moment a
    // scan added one new extreme (see PreferenceRanker's type doc comment).
    // All optional, and nil means exactly one thing: this photo was not
    // measured for it — analyzed before the trait existed, or the measurement
    // did not resolve. FR-3.8 forbids reading that gap as a low value, so the
    // ranker substitutes the trait's own neutral midpoint and trains nothing
    // on it. Defaults are `nil` so SwiftData migrates existing records
    // without a schema version; the analysis-version bump that introduced
    // them re-measures every record in the background anyway (FR-5.2).

    /// Tallest face or confident human rectangle as a fraction of frame
    /// height — the same quantity `Thresholds.personProminenceHeight` gates
    /// on, kept so the user's choices can weigh where inside the admitted
    /// band their own line falls (FR-3.1).
    var personProminence: Float?

    /// Fraction of the frame covered by the largest attention-salient region;
    /// 0 when the frame has no dominant subject.
    var subjectProminence: Float?

    /// How centred that dominant region is — 1 at the frame's centre, 0 at
    /// the furthest corner.
    var subjectCentrality: Float?

    /// Mean relative luminance, 0 (black) … 1 (white).
    var luminance: Float?

    /// Mean chroma, 0 (fully desaturated) … 1 (fully saturated).
    var colorfulness: Float?

    /// Fraction of the frame covered by segmented foreground objects.
    var foregroundCoverage: Float?

    /// How many distinct foreground objects were separated out. Stored as the
    /// raw count; the ranker is what puts it on a fixed 0…1 scale.
    var subjectCount: Int?

    /// Tallest recognized animal as a fraction of frame height, 0 when there
    /// is none. Species-blind — only the geometry is kept.
    var animalProminence: Float?

    /// Fraction of the frame covered by detected text regions.
    var textCoverage: Float?

    init(
        localIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        creationDate: Date?,
        location: CLLocation?,
        isFavorite: Bool,
        mediaSubtypes: Int?
    ) {
        self.localIdentifier = localIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.latitude = location?.coordinate.latitude
        self.longitude = location?.coordinate.longitude
        self.altitude = location?.altitude
        self.cameraHeading = (location?.course).flatMap { $0 >= 0 ? $0 : nil }
        self.mediaSubtypes = mediaSubtypes
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
