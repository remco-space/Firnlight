import Foundation
import SwiftData

/// One pairwise duel decision. All choices are kept so the ranker can be
/// retrained from scratch (delete the weights file → replay choices).
///
/// Keyed by `PhotoRecord.judgmentKey`, not by local identifier: a choice made
/// on one device has to count on all of them, against the same photo (FR-9.1).
/// Note that the carrying is not switched on — both stores are
/// `cloudKitDatabase: .none` (see `JudgmentStore`), so this key is currently
/// portable in principle rather than in practice.
/// The stored columns keep their original names via `originalName:` so the
/// meaning change needs no column migration — the same trick
/// `PhotoRecord.isExcluded` uses.
///
/// Lives in the "Judgments" store rather than alongside `PhotoRecord`: this is
/// the user's own judgment, the only thing FR-1.5 permits leaving the device,
/// and it is deliberately shaped to satisfy CloudKit's mirroring rules — every
/// attribute has a default value, there are no relationships, and there is no
/// unique constraint (CloudKit rejects all three). Nothing here is photo
/// content: an opaque identifier, and which of two won.
@Model
final class ChoiceRecord {
    @Attribute(originalName: "winnerID") var winnerKey: String = ""
    @Attribute(originalName: "loserID") var loserKey: String = ""
    var timestamp: Date = Date.distantPast
    /// FR-5.12: the correction path for a duel choice. A choice has no
    /// separate "cleared" record shape the way `VerdictRecord` does — nothing
    /// else in the app displays "you chose X over Y" for a later toggle to
    /// act on, so there is nothing to append a clearing row against. Instead
    /// the row that would be un-said is marked in place, the same append-only
    /// philosophy applied to the one row it actually concerns: every reader
    /// that walks `ChoiceRecord` for training or for the judged-pairs set
    /// excludes a voided row, so a voided choice behaves as if it had never
    /// been made (FR-5.2's "outcome as if the corrected judgment had always
    /// been the one given"). Only ever set moments after the choice, by
    /// `PreferenceRanker.undoLastChoice` — see its doc comment for why voiding
    /// forces the same full-replay rebuild `clearVerdicts` already takes.
    /// Defaulted, like every other attribute here, so the shape stays
    /// CloudKit-mirrorable.
    var isVoided: Bool = false

    init(winnerKey: String, loserKey: String, timestamp: Date, isVoided: Bool = false) {
        self.winnerKey = winnerKey
        self.loserKey = loserKey
        self.timestamp = timestamp
        self.isVoided = isVoided
    }
}
