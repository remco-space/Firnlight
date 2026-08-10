import Foundation
import SwiftData

/// The durable, shareable truth behind "Ignore This Photo" (FR-4.8).
///
/// **Nothing here reaches another device yet.** Both stores are
/// `cloudKitDatabase: .none` — see `JudgmentStore` — because the iCloud
/// container entitlement can't be provisioned on this project's signing team.
/// The keys, the split and the merge rules below are what FR-9.1 needs and
/// are in place; the transport is not, so today this is a local record that
/// happens to be shaped for sharing.
///
/// Ignoring is a judgment, not derived analysis, so FR-9.1 puts it in the same
/// class as choices and verdicts: made on one device, it counts on all of
/// them, against the same photo. That is why it cannot simply live on
/// `PhotoRecord` — that record is local-only derived analysis (feature prints,
/// scores, dimensions) which never leaves the device under FR-1.5.
/// `PhotoRecord.isExcluded` survives as a denormalized *cache* of the latest
/// record here, because the grid, duel and album fetches filter on it inside
/// `#Predicate`s that cannot join across stores — exactly the role
/// `preferenceScore` already plays for the ranker.
///
/// Append-only with last-timestamp-wins rather than insert/delete: the flag is
/// a toggle, and two devices toggling it apart must resolve to whichever the
/// user did last, not to whichever synced last. Choices and verdicts never
/// conflict because they are pure additions; this is the one value that can,
/// and last-write-wins is the only sane reading of a user's own switch.
///
/// Shaped for CloudKit mirroring like its siblings — defaults on every
/// attribute, no relationships, no unique constraint — so the day section 9's
/// transport is switchable, nothing here has to change.
@Model
final class IgnoreRecord {
    /// `PhotoRecord.judgmentKey`.
    var photoKey: String = ""
    var isIgnored: Bool = false
    var timestamp: Date = Date.distantPast

    init(photoKey: String, isIgnored: Bool, timestamp: Date) {
        self.photoKey = photoKey
        self.isIgnored = isIgnored
        self.timestamp = timestamp
    }
}
