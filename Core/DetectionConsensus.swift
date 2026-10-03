import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Multi-frame consensus: een pijlpositie wordt pas goedgekeurd als het model hem in
/// `requiredFrames` OPEENVOLGENDE beelden binnen `radius` pixels terugvindt.
/// Een hand, schaduw of vliegende pijl staat zelden 3 beelden op exact dezelfde plek.
struct DetectionConsensus {
    /// Aantal opeenvolgende beelden (standaard 3).
    var requiredFrames = 3
    /// Maximale afwijking van het middelpunt (pixels, zelfde eenheid als de kandidaten).
    var radius = 5.0
    /// Na zoveel beelden zonder consensus: opgeven (val terug op het verschilbeeld).
    var maxFrames = 6

    private(set) var history: [[CGPoint]] = []

    var isExhausted: Bool { history.count >= maxFrames }

    mutating func reset() { history = [] }

    /// Voeg de kandidaten (nieuwe pijlpunten) van één beeld toe.
    /// - Returns: het gemiddelde punt zodra er consensus is, anders nil.
    mutating func add(_ candidates: [CGPoint]) -> CGPoint? {
        history.append(candidates)
        guard history.count >= requiredFrames else { return nil }
        let window = history.suffix(requiredFrames)
        for c in window.last! {
            var chain = [c]
            var ok = true
            for frame in window.dropLast().reversed() {
                guard let match = frame.min(by: { dist($0, c) < dist($1, c) }), dist(match, c) <= radius else {
                    ok = false
                    break
                }
                chain.append(match)
            }
            if ok {
                let n = Double(chain.count)
                return CGPoint(x: chain.reduce(0) { $0 + Double($1.x) } / n,
                               y: chain.reduce(0) { $0 + Double($1.y) } / n)
            }
        }
        return nil
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }
}
