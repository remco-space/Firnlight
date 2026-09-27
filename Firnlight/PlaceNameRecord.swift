import Foundation
import SwiftData

/// What Apple's maps service answered, once, for one rounded coordinate —
/// FR-5.13's "a lookup asks about each place once and remembers the
/// answer."
///
/// Keyed by `PlaceHierarchy.networkCacheKey`, not by photo: many photos
/// taken near one another round to the same key, and the point of caching
/// here rather than only on `PhotoRecord` is that they share one lookup —
/// the second photo taken nearby never costs a second round trip
/// (`PlaceNameLookup.nextPendingSpot` skips any cell already recorded
/// here). The cache key itself is purely a deduplication grid, never a
/// place identity in its own right; `cityName` is what
/// `PlaceHierarchy.networkPlaceKey` anchors into FR-5.14's fifth scale
/// (`regionName` is cached here too, but no longer part of that key — see
/// its own doc comment for why), written onto every matching `PhotoRecord`
/// by `PlaceNameLookup.save` — this row is the lookup-side cache,
/// `PhotoRecord.networkPlaceName` is what ranking and the FR-6.1 mix
/// actually read (see `PlaceHierarchy`'s doc comment for why that scale is
/// always kept separate from `PlaceGazetteer`'s four offline ones).
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
    /// name half of FR-5.14's fifth scale (see
    /// `PlaceHierarchy.networkPlaceKey`; the other half, the
    /// disambiguating anchor, comes from the offline gazetteer, not from
    /// Apple). Nil when the service answered but had no city name for this
    /// location (open water, a wilderness with no indexed settlement
    /// nearby).
    var cityName: String?

    /// What Apple's maps service calls this spot's country
    /// (`MKAddressRepresentations.regionName`, which Apple's own header
    /// example gives as "United States": despite the property's name this
    /// is the country-level answer, not a state or province — see
    /// `PlaceNameLookup`). Cached here as part of what was asked and
    /// answered, but no longer part of `networkPlaceKey`'s composed key —
    /// verified (a standalone `MKReverseGeocodingRequest` harness against
    /// five real coordinates: Springfield, MA/IL/MO and Las Vegas, NV/NM)
    /// that this value is identical for every one of them ("United
    /// States"), so it cannot disambiguate the collision the anchor exists
    /// to prevent. Nil under the same circumstances as `cityName`.
    var regionName: String?

    var lookedUpAt: Date

    init(cacheKey: String, cityName: String?, regionName: String?, lookedUpAt: Date = Date()) {
        self.cacheKey = cacheKey
        self.cityName = cityName
        self.regionName = regionName
        self.lookedUpAt = lookedUpAt
    }
}
