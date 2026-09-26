import Foundation
import SwiftData

/// What Apple's maps service answered, once, for one fine-grained
/// `PlaceHierarchy` cell — FR-5.13's "a lookup asks about each place once and
/// remembers the answer."
///
/// Keyed by `PlaceHierarchy.ScaleKeys.fine`, not by photo: many photos share
/// one fine cell, and the point of caching here rather than on `PhotoRecord`
/// is that they share one lookup too — the second photo in the same town
/// never costs a second round trip. `cityName`/`regionName` come from
/// `MKAddressRepresentations` (see `PlaceNameLookup`), and either or both may
/// be nil — a genuine answer, not a failure: open water and unindexed places
/// resolve to nothing nameable, and that is remembered exactly like a real
/// name is, so the cell is never asked again. A row's mere presence is "this
/// cell has been asked about"; a *failed* attempt (no network, a thrown
/// error) inserts no row at all, so `PlaceNameLookup` retries it later
/// exactly as `PhotoRecord.isSkipped` retries a deferred iCloud download
/// (FR-3.4's pattern, applied here to a different kind of deferred work).
///
/// Lives in the same store as `PhotoRecord` (see `JudgmentStore`), never the
/// judgments store: this is derived, rebuildable-with-a-network-connection
/// data, the same category `PhotoRecord.featurePrint` already is — not
/// something the user decided, so FR-7.4's export/FR-7.5's reset both leave
/// it alone exactly as they already leave analysis data alone.
@Model
final class PlaceNameRecord {
    @Attribute(.unique) var fineCellKey: String

    /// FR-5.14's fine scale, named — a town or park. Nil when the service
    /// answered but had no city name for this location (open water, a
    /// wilderness with no indexed settlement nearby).
    var cityName: String?

    /// FR-5.14's coarse scale, named — a country (`MKAddressRepresentations
    /// .regionName`, which Apple's own header example gives as "United
    /// States": despite the property's name this is the country-level
    /// answer, not a state or province — see `PlaceNameLookup`). Nil under
    /// the same circumstances as `cityName`.
    var regionName: String?

    var lookedUpAt: Date

    init(fineCellKey: String, cityName: String?, regionName: String?, lookedUpAt: Date = Date()) {
        self.fineCellKey = fineCellKey
        self.cityName = cityName
        self.regionName = regionName
        self.lookedUpAt = lookedUpAt
    }
}
