import Foundation
import SwiftData

/// One pairwise duel decision. All choices are kept so the ranker can be
/// retrained from scratch (delete the weights file → replay choices).
@Model
final class ChoiceRecord {
    var winnerID: String
    var loserID: String
    var timestamp: Date

    init(winnerID: String, loserID: String, timestamp: Date) {
        self.winnerID = winnerID
        self.loserID = loserID
        self.timestamp = timestamp
    }
}
