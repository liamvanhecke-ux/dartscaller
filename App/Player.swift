import Foundation
import SwiftData

@Model
final class Player {
    @Attribute(.unique) var uuid: UUID
    var name: String
    var nickname: String
    var createdAt: Date
    var gamesPlayed: Int
    var gamesWon: Int
    var bestAverage: Double

    init(name: String, nickname: String = "") {
        self.uuid = UUID()
        self.name = name
        self.nickname = nickname
        self.createdAt = Date()
        self.gamesPlayed = 0
        self.gamesWon = 0
        self.bestAverage = 0
    }

    var displayName: String { nickname.trimmingCharacters(in: .whitespaces).isEmpty ? name : nickname }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Lichte, niet-persistente kopie van een speler voor tijdens de wedstrijd.
struct GamePlayer: Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct GameConfig: Identifiable {
    let id = UUID()
    var players: [GamePlayer]
    var startScore: Int
    var doubleOut: Bool
    var bullOff: Bool
    var useCamera: Bool
}
