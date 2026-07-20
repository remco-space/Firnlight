import Foundation
import SwiftData

/// An absolute quality verdict from the duel's "Both Are Great" / "Both Are
/// Bad" buttons. Unlike ChoiceRecord (relative preference), verdicts anchor
/// where the wallpaper-worthiness bar sits on the score scale — used to
/// calibrate the suggested album size.
@Model
final class VerdictRecord {
    var localIdentifier: String
    var isGood: Bool
    var timestamp: Date

    init(localIdentifier: String, isGood: Bool, timestamp: Date) {
        self.localIdentifier = localIdentifier
        self.isGood = isGood
        self.timestamp = timestamp
    }
}
