import Foundation
import Observation

// MARK: - Types

enum TurnOutcome: String, Codable, Equatable {
    case scored, bust, checkout
}

/// Eén afgesloten beurt. De stand wordt ALTIJD herberekend uit deze lijst (event sourcing),
/// zodat een correctie in een oude beurt automatisch alle latere standen juist zet.
struct TurnRecord: Identifiable, Equatable, Codable {
    var id = UUID()
    var seatIndex: Int
    var darts: [DartHit]
    // Hieronder: berekend door replay()
    var outcome: TurnOutcome = .scored
    var startRemaining: Int = 0
    var endRemaining: Int = 0

    /// Punten die daadwerkelijk van de stand afgaan (0 bij bust).
    var countedPoints: Int { outcome == .bust ? 0 : startRemaining - endRemaining }
    /// Som van de gegooide pijlen, ook bij bust (voor weergave).
    var thrownPoints: Int { darts.reduce(0) { $0 + $1.score } }
}

enum GameEvent: Equatable {
    case dart(DartHit)
    case turnEnded(TurnRecord)
    case turnCorrected(TurnRecord)
    case legWon(seatIndex: Int)
}

enum AmendResult: Equatable {
    /// Beurt aangepast en blijft afgesloten.
    case updated
    /// De laatste beurt is weer geopend (bv. bust ongedaan gemaakt terwijl er nog een pijl gegooid mag worden).
    case reopened(dartsInTurn: Int)
    case notFound
}

// MARK: - Engine

@Observable
final class X01Engine {

    enum Phase: Equatable {
        /// Huidige speler is aan het gooien.
        case throwing
        /// Beurt klaar, wachten tot de pijlen uit het bord zijn (of "Volgende speler").
        case awaitingNext
        /// Leg gewonnen.
        case finished
    }

    struct Seat: Identifiable, Equatable {
        let id: UUID
        let name: String
        var remaining: Int
    }

    static let startOptions = [101, 201, 301, 501, 701]

    let startScore: Int
    let doubleOut: Bool

    private(set) var seats: [Seat]
    private(set) var current: Int = 0
    private(set) var turn: [DartHit] = []
    private(set) var phase: Phase = .throwing
    private(set) var records: [TurnRecord] = []
    private(set) var winnerIndex: Int?

    /// Wordt aangeroepen voor audio, camera en UI. Altijd synchroon op de aanroepende thread (MainActor in de app).
    @ObservationIgnored var onEvent: ((GameEvent) -> Void)?

    init(players: [(id: UUID, name: String)], startScore: Int, doubleOut: Bool = true) {
        precondition(!players.isEmpty, "Minstens 1 speler nodig")
        self.startScore = startScore
        self.doubleOut = doubleOut
        self.seats = players.map { Seat(id: $0.id, name: $0.name, remaining: startScore) }
    }

    // MARK: Afgeleide waarden

    var currentSeat: Seat { seats[current] }
    var winner: Seat? { winnerIndex.map { seats[$0] } }

    /// Stand van de huidige speler inclusief de pijlen van deze beurt.
    var liveRemaining: Int {
        guard phase == .throwing else { return seats[current].remaining }
        let ev = Self.evaluate(turn, start: seats[current].remaining, doubleOut: doubleOut)
        return ev.outcome == .bust ? seats[current].remaining : seats[current].remaining - turn.reduce(0) { $0 + $1.score }
    }

    var dartsLeftInTurn: Int { phase == .throwing ? 3 - turn.count : 0 }

    /// De pijlen die nu "in het bord" horen: lopende beurt, of de net afgesloten beurt.
    var visibleDarts: [DartHit] {
        if phase == .throwing { return turn }
        return records.last?.darts ?? []
    }

    func records(for seatIndex: Int) -> [TurnRecord] { records.filter { $0.seatIndex == seatIndex } }

    /// 3-dart gemiddelde (PDC-methode: gegooide pijlen tellen, bust = 0 punten).
    func threeDartAverage(for seatIndex: Int) -> Double {
        let recs = records(for: seatIndex)
        let darts = recs.reduce(0) { $0 + $1.darts.count }
        guard darts > 0 else { return 0 }
        let points = recs.reduce(0) { $0 + $1.countedPoints }
        return Double(points) / Double(darts) * 3
    }

    func dartsThrown(by seatIndex: Int) -> Int { records(for: seatIndex).reduce(0) { $0 + $1.darts.count } }

    // MARK: Regels

    struct Evaluation: Equatable {
        enum Outcome: Equatable { case ongoing, bust, checkout }
        let outcome: Outcome
        /// Aantal pijlen dat meetelt (pijlen na bust/checkout vervallen).
        let usedDarts: Int
    }

    static func evaluate(_ darts: [DartHit], start: Int, doubleOut: Bool) -> Evaluation {
        var rem = start
        for (i, d) in darts.enumerated() {
            rem -= d.score
            if rem == 0 {
                return Evaluation(outcome: (!doubleOut || d.isDouble) ? .checkout : .bust, usedDarts: i + 1)
            }
            if rem < 0 || (doubleOut && rem == 1) {
                return Evaluation(outcome: .bust, usedDarts: i + 1)
            }
        }
        return Evaluation(outcome: .ongoing, usedDarts: darts.count)
    }

    // MARK: Invoer (camera en handmatig volgen exact hetzelfde pad)

    func register(_ hit: DartHit) {
        guard phase == .throwing, turn.count < 3 else { return }
        turn.append(hit)
        onEvent?(.dart(hit))
        let ev = Self.evaluate(turn, start: seats[current].remaining, doubleOut: doubleOut)
        if ev.outcome != .ongoing || turn.count == 3 { closeTurn() }
    }

    /// Speler loopt naar het bord / "Beurt bevestigen": ontbrekende pijlen worden MIS.
    func completeTurnWithMisses() {
        guard phase == .throwing else { return }
        while phase == .throwing { register(.miss) }
    }

    /// Pijlen zijn uit het bord → volgende speler.
    func nextPlayer() {
        guard phase == .awaitingNext, let last = records.last else { return }
        current = (last.seatIndex + 1) % seats.count
        turn = []
        phase = .throwing
    }

    // MARK: Correcties

    /// Pas één pijl van de lopende beurt aan (index 0...2). index == turn.count voegt een pijl toe.
    func setCurrentDart(at index: Int, to hit: DartHit) {
        guard phase == .throwing else { return }
        if index == turn.count {
            register(hit)
            return
        }
        guard turn.indices.contains(index) else { return }
        turn[index] = hit
        let ev = Self.evaluate(turn, start: seats[current].remaining, doubleOut: doubleOut)
        if ev.outcome != .ongoing || turn.count == 3 { closeTurn() }
    }

    /// Verwijdert de laatst geregistreerde pijl (ook als de beurt daardoor weer open gaat).
    /// Geeft het aantal pijlen in de heropende beurt terug, of nil als er niets te doen was.
    @discardableResult
    func undoLastDart() -> Int? {
        switch phase {
        case .throwing:
            if !turn.isEmpty {
                turn.removeLast()
                return turn.count
            }
            // Beurt is nog leeg: ga terug naar de vorige beurt.
            guard let last = records.popLast() else { return nil }
            reopen(last, dropLast: true)
            return turn.count
        case .awaitingNext, .finished:
            guard let last = records.popLast() else { return nil }
            reopen(last, dropLast: true)
            return turn.count
        }
    }

    /// Vervang de pijlen van een afgesloten beurt. Alle standen daarna worden herberekend.
    @discardableResult
    func amendTurn(id: TurnRecord.ID, darts newDarts: [DartHit]) -> AmendResult {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return .notFound }
        let darts = Array(newDarts.prefix(3))
        let isLast = idx == records.count - 1

        // Laatste beurt, bord nog niet leeggemaakt, en na correctie mag er nog gegooid worden → heropenen.
        if isLast && phase != .throwing {
            let start = records[idx].startRemaining
            let ev = Self.evaluate(darts, start: start, doubleOut: doubleOut)
            if ev.outcome == .ongoing && darts.count < 3 {
                var rec = records.removeLast()
                rec.darts = darts
                reopen(rec, dropLast: false)
                return .reopened(dartsInTurn: turn.count)
            }
        }

        records[idx].darts = darts.isEmpty ? [.miss] : darts
        replay()
        if let w = winnerIndex {
            phase = .finished
            current = records.last?.seatIndex ?? current
            turn = []
            onEvent?(.turnCorrected(records[min(idx, records.count - 1)]))
            onEvent?(.legWon(seatIndex: w))
            return .updated
        }
        if phase == .finished { phase = .awaitingNext }
        if idx < records.count { onEvent?(.turnCorrected(records[idx])) }

        // Een correctie in het verleden kan de lopende beurt ongeldig maken (bv. nu bust).
        if phase == .throwing && !turn.isEmpty {
            let ev = Self.evaluate(turn, start: seats[current].remaining, doubleOut: doubleOut)
            if ev.outcome != .ongoing || turn.count == 3 { closeTurn() }
        }
        return .updated
    }

    // MARK: Intern

    private func reopen(_ record: TurnRecord, dropLast: Bool) {
        var darts = record.darts
        if dropLast, !darts.isEmpty { darts.removeLast() }
        current = record.seatIndex
        turn = darts
        phase = .throwing
        replay()
        // Heropende beurt kan (door correctie) nog steeds klaar zijn.
        let ev = Self.evaluate(turn, start: seats[current].remaining, doubleOut: doubleOut)
        if ev.outcome != .ongoing || turn.count == 3 { closeTurn() }
    }

    private func closeTurn() {
        records.append(TurnRecord(seatIndex: current, darts: turn))
        turn = []
        replay()
        guard let rec = records.last else { return }
        if let w = winnerIndex {
            phase = .finished
            onEvent?(.turnEnded(rec))
            onEvent?(.legWon(seatIndex: w))
        } else {
            phase = .awaitingNext
            onEvent?(.turnEnded(rec))
        }
    }

    /// Herberekent alle standen uit `records`.
    private func replay() {
        var remaining = Array(repeating: startScore, count: seats.count)
        var rebuilt: [TurnRecord] = []
        winnerIndex = nil

        for var r in records {
            let start = remaining[r.seatIndex]
            let ev = Self.evaluate(r.darts, start: start, doubleOut: doubleOut)
            r.darts = Array(r.darts.prefix(ev.usedDarts))
            if ev.outcome == .ongoing {
                while r.darts.count < 3 { r.darts.append(.miss) }   // afgesloten beurt = altijd 3 pijlen
            }
            r.startRemaining = start
            switch ev.outcome {
            case .ongoing:
                r.outcome = .scored
                remaining[r.seatIndex] = start - r.darts.reduce(0) { $0 + $1.score }
            case .bust:
                r.outcome = .bust
            case .checkout:
                r.outcome = .checkout
                remaining[r.seatIndex] = 0
            }
            r.endRemaining = remaining[r.seatIndex]
            rebuilt.append(r)
            if ev.outcome == .checkout {
                winnerIndex = r.seatIndex
                break   // alles na een checkout vervalt
            }
        }
        records = rebuilt
        for i in seats.indices { seats[i].remaining = remaining[i] }
    }
}

// MARK: - Bull-off: dichtst bij het middelpunt begint

enum BullOff {
    enum Result: Equatable {
        case winner(UUID)
        /// Gelijkspel (of niemand raakte het bord): deze spelers gooien opnieuw.
        case rethrow([UUID])
    }

    /// `throws_`: per speler de worp (nil / mis / geen positie = oneindig ver).
    /// Verschil kleiner dan `tieToleranceMM` telt als gelijk.
    static func decide(_ throws_: [(player: UUID, hit: DartHit?)], tieToleranceMM: Double = 1.0) -> Result {
        let measured = throws_.map { ($0.player, $0.hit?.isMiss == false ? ($0.hit?.distanceToCenterMM ?? .infinity) : .infinity) }
        guard let best = measured.map(\.1).min(), best.isFinite else {
            return .rethrow(throws_.map(\.player))
        }
        let closest = measured.filter { $0.1 - best < tieToleranceMM }.map(\.0)
        return closest.count == 1 ? .winner(closest[0]) : .rethrow(closest)
    }

    /// Winnaar begint, daarna de rest in de oorspronkelijke volgorde (doorlopend).
    static func order(_ players: [UUID], startingWith winner: UUID) -> [UUID] {
        guard let i = players.firstIndex(of: winner) else { return players }
        return Array(players[i...] + players[..<i])
    }
}
