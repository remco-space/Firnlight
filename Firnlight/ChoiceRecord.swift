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

    init(winnerKey: String, loserKey: String, timestamp: Date) {
        self.winnerKey = winnerKey
        self.loserKey = loserKey
        self.timestamp = timestamp
    }
}
