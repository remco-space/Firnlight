import Foundation
import SwiftData

/// What Apple's maps service answered, once, for one rounded coordinate —
/// FR-5.13's "a lookup asks about each place once and remembers the
/// answer."
///
/// Keyed by `PlaceHierarchy.networkCacheKey`, not by photo: many photos
/// taken near one another round to the same key, and the point of caching
/// here rather than on `PhotoRecord` is that they share one lookup too — the
/// second photo taken nearby never costs a second round trip. The key is
/// purely a cache-deduplication grid — it is not, and `cityName`/`regionName`
/// below are not, the place identity ranking or the FR-6.1 mix ever reads;
/// that is always `PlaceGazetteer`'s real, published, offline names (see
/// `PlaceHierarchy`'s doc comment for why this row's answer is kept purely
/// informational rather than feeding those keys).
///
/// `cityName`/`regionName` come from `MKAddressRepresentations` (see
/// `PlaceNameLookup`), and either or both may be nil — a genuine answer, not
/// a failure: open water and unindexed places resolve to nothing nameable,
/// and that is remembered exactly like a real name is, so the spot is never
/// asked about again. A row's mere presence is "this spot has been asked
/// about"; a *failed* attempt (no network, a thrown error) inserts no row at
/// all, so `PlaceNameLookup` retries it later exactly as
/// `PhotoRecord.isSkipped` retries a deferred iCloud download (FR-3.4's
/// pattern, applied here to a different kind of deferred work).
///
/// Lives in the same store as `PhotoRecord` (see `JudgmentStore`), never the
/// judgments store: this is derived, rebuildable-with-a-network-connection
/// data, the same category `PhotoRecord.featurePrint` already is — not
/// something the user decided, so FR-7.4's export/FR-7.5's reset both leave
/// it alone exactly as they already leave analysis data alone.
@Model
final class PlaceNameRecord {
    @Attribute(.unique) var cacheKey: String

    /// What Apple's maps service calls this spot's town or settlement — the
    /// same kind of answer as FR-5.14's fine scale, but informational only
    /// (see this type's own doc comment); never read as that scale's
    /// ranking key. Nil when the service answered but had no city name for
    /// this location (open water, a wilderness with no indexed settlement
    /// nearby).
    var cityName: String?

    /// What Apple's maps service calls this spot's country
    /// (`MKAddressRepresentations.regionName`, which Apple's own header
    /// example gives as "United States": despite the property's name this
    /// is the country-level answer, not a state or province — see
    /// `PlaceNameLookup`) — the same kind of answer as FR-5.14's coarse
    /// scale, informational only, never read as that scale's ranking key.
    /// Nil under the same circumstances as `cityName`.
    var regionName: String?

    var lookedUpAt: Date

    init(cacheKey: String, cityName: String?, regionName: String?, lookedUpAt: Date = Date()) {
        self.cacheKey = cacheKey
        self.cityName = cityName
        self.regionName = regionName
        self.lookedUpAt = lookedUpAt
    }
}
