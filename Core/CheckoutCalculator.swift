import Foundation

/// Berekent een uitgooi-route voor een resterende score met maximaal `dartsLeft` pijlen.
/// Rangschikking: minste pijlen → minste risico → favoriete double → hoogste eerste pijl.
enum CheckoutCalculator {

    /// Scores die niet in 3 pijlen uit te gooien zijn met double-out.
    static let bogeyNumbers: Set<Int> = [159, 162, 163, 165, 166, 168, 169]

    private static let preferredDoubles = [20, 16, 8, 18, 12, 10, 4, 2, 6, 14, 3, 1, 5, 7, 9, 11, 13, 15, 17, 19, 25]

    private static let setupDarts: [DartHit] = {
        var d: [DartHit] = []
        for s in 1...20 { d.append(.single(s)); d.append(.double(s)); d.append(.triple(s)) }
        d.append(.outerBull); d.append(.bull)
        return d
    }()

    private static let finishDarts: [DartHit] = (1...20).map { DartHit.double($0) } + [.bull]

    private static var cache: [Int: [DartHit]] = [:]
    private static let lock = NSLock()

    /// nil = niet uit te gooien met dit aantal pijlen.
    static func suggestion(for remaining: Int, dartsLeft: Int = 3, doubleOut: Bool = true) -> [DartHit]? {
        guard doubleOut, dartsLeft >= 1, remaining >= 2, remaining <= 170 else {
            return doubleOut ? nil : simpleOut(remaining, dartsLeft: dartsLeft)
        }
        let key = remaining * 10 + dartsLeft
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        let result = search(remaining, dartsLeft: dartsLeft)
        cache[key] = result ?? []
        return result
    }

    static func label(for route: [DartHit]) -> String {
        route.map(\.shortLabel).joined(separator: " · ")
    }

    // MARK: - Zoeken

    private static func risk(_ d: DartHit) -> Double {
        switch (d.segment, d.multiplier) {
        case (25, 2): return 2.5   // bull als opzet-pijl is lastig
        case (25, 1): return 1.2
        case (_, 3):  return 1.0
        case (_, 2):  return 1.5   // double als opzet-pijl
        default:      return 0.0
        }
    }

    private static func doubleRank(_ d: DartHit) -> Int {
        preferredDoubles.firstIndex(of: d.segment) ?? 99
    }

    private static func search(_ r: Int, dartsLeft: Int) -> [DartHit]? {
        var best: [DartHit]?
        var bestKey: (Int, Double, Int, Int)?

        func consider(_ route: [DartHit]) {
            let setupRisk = route.dropLast().reduce(0.0) { $0 + risk($1) }
            let key = (route.count, setupRisk, doubleRank(route.last!), -(route.first?.score ?? 0))
            if let k = bestKey, !(key < k) { return }
            bestKey = key
            best = route
        }

        for f in finishDarts where f.score == r { consider([f]) }
        if dartsLeft >= 2 {
            for a in setupDarts {
                for f in finishDarts where a.score + f.score == r { consider([a, f]) }
            }
        }
        if dartsLeft >= 3 && best == nil {
            for a in setupDarts where a.score < r {
                for b in setupDarts where a.score + b.score < r {
                    for f in finishDarts where a.score + b.score + f.score == r {
                        // Hogere pijl eerst (T20 T19 i.p.v. T19 T20)
                        if b.score > a.score { continue }
                        consider([a, b, f])
                    }
                }
            }
        }
        return best
    }

    /// Zonder double-out: gewoon één combinatie tonen.
    private static func simpleOut(_ r: Int, dartsLeft: Int) -> [DartHit]? {
        guard r > 0 else { return nil }
        let all = setupDarts
        for a in all where a.score == r { return [a] }
        if dartsLeft >= 2 { for a in all { for b in all where a.score + b.score == r && a.score >= b.score { return [a, b] } } }
        return nil
    }
}
