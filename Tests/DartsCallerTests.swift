import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if !os(Linux)
@testable import DartsCaller
#endif

final class BoardGeometryTests: XCTestCase {

    private func hit(r: Double, deg: Double) -> DartHit {
        let a = deg * .pi / 180
        return BoardGeometry.hit(at: CGPoint(x: r * cos(a), y: r * sin(a)))
    }

    func testSegmentsAroundTheBoard() {
        for (i, seg) in BoardGeometry.order.enumerated() {
            let center = 90 - Double(i) * 18
            XCTAssertEqual(hit(r: 60, deg: center).segment, seg, "midden van \(seg)")
            XCTAssertEqual(hit(r: 60, deg: center + 8.5).segment, seg, "linkerrand van \(seg)")
            XCTAssertEqual(hit(r: 60, deg: center - 8.5).segment, seg, "rechterrand van \(seg)")
        }
    }

    func testRings() {
        XCTAssertEqual(hit(r: 3, deg: 10).shortLabel, "BULL")
        XCTAssertEqual(hit(r: 10, deg: 10).shortLabel, "25")
        XCTAssertEqual(hit(r: 103, deg: 90).shortLabel, "T20")
        XCTAssertEqual(hit(r: 166, deg: 90).shortLabel, "D20")
        XCTAssertEqual(hit(r: 130, deg: 90).shortLabel, "S20")
        XCTAssertEqual(hit(r: 50, deg: 90).shortLabel, "S20")
        XCTAssertTrue(hit(r: 175, deg: 90).isMiss)
        XCTAssertEqual(hit(r: 103, deg: 0).shortLabel, "T6")
        XCTAssertEqual(hit(r: 103, deg: -90).shortLabel, "T3")
        XCTAssertEqual(hit(r: 103, deg: 180).shortLabel, "T11")
    }

    func testHomographyRoundTrip() {
        // Schuin perspectief: willekeurige 4 beeldpunten.
        let img = [CGPoint(x: 612, y: 190), CGPoint(x: 905, y: 540), CGPoint(x: 560, y: 1010), CGPoint(x: 240, y: 520)]
        guard let h = Homography(from: img, to: BoardGeometry.calibrationPointsMM), let inv = h.inverse else {
            return XCTFail("homografie")
        }
        for (p, q) in zip(img, BoardGeometry.calibrationPointsMM) {
            let m = h.apply(p)
            XCTAssertEqual(Double(m.x), Double(q.x), accuracy: 1e-6)
            XCTAssertEqual(Double(m.y), Double(q.y), accuracy: 1e-6)
            let back = inv.apply(m)
            XCTAssertEqual(Double(back.x), Double(p.x), accuracy: 1e-6)
            XCTAssertEqual(Double(back.y), Double(p.y), accuracy: 1e-6)
        }
    }

    func testCalibrationDetectsCameraBelowBoard() {
        // Simuleer camera onder het bord: onderkant (y groot in beeld) breder dan bovenkant.
        let toImage = { (p: CGPoint) -> CGPoint in
            let x = Double(p.x), y = Double(p.y)
            let w = 1 + y * 0.0012             // bovenkant verder weg → kleiner
            return CGPoint(x: 540 + x * 2 / w, y: 960 - y * 1.6 / w)
        }
        let pts = BoardGeometry.calibrationPointsMM.map(toImage)
        guard let cal = BoardCalibration(imagePoints: pts, imageSize: CGSize(width: 1080, height: 1920)) else {
            return XCTFail("kalibratie")
        }
        let dir = try! XCTUnwrap(cal.cameraSideDirection)
        XCTAssertGreaterThan(Double(dir.dy), 0.9, "camera zit onder → richting omlaag in beeld")
        // Middelpunt terugrekenen
        let c = cal.toBoard.apply(toImage(.zero))
        XCTAssertEqual(Double(c.x), 0, accuracy: 0.01)
        XCTAssertEqual(Double(c.y), 0, accuracy: 0.01)
        // Een punt in T20 blijft T20
        XCTAssertEqual(BoardGeometry.hit(at: cal.toBoard.apply(toImage(CGPoint(x: 0, y: 103)))).shortLabel, "T20")
    }
}

final class X01EngineTests: XCTestCase {

    private let a = UUID(), b = UUID()
    private func engine(_ start: Int = 501) -> X01Engine {
        X01Engine(players: [(a, "Liam"), (b, "Jonas")], startScore: start)
    }

    func testThreeDartsScoreAndSwitch() {
        let e = engine()
        e.register(.triple(20)); e.register(.triple(20)); e.register(.triple(20))
        XCTAssertEqual(e.phase, .awaitingNext)
        XCTAssertEqual(e.seats[0].remaining, 321)
        XCTAssertEqual(e.records.last?.countedPoints, 180)
        e.nextPlayer()
        XCTAssertEqual(e.current, 1)
        XCTAssertEqual(e.phase, .throwing)
    }

    func testIgnoresDartsWhileAwaitingNext() {
        let e = engine()
        e.register(.single(1)); e.register(.single(1)); e.register(.single(1))
        e.register(.triple(20))   // bv. valse detectie vóór bord leeg
        XCTAssertEqual(e.seats[0].remaining, 498)
        XCTAssertEqual(e.records.count, 1)
    }

    /// Specificatie: 2 pijlen gedetecteerd, speler loopt naar het bord → pijl 3 = MIS, beurt dicht.
    func testPersonAtBoardFillsMisses() {
        let e = engine()
        var events: [GameEvent] = []
        e.onEvent = { events.append($0) }
        e.register(.single(20)); e.register(.single(5))
        e.completeTurnWithMisses()
        XCTAssertEqual(e.phase, .awaitingNext)
        XCTAssertEqual(e.records.last?.darts.map(\.shortLabel), ["S20", "S5", "MIS"])
        XCTAssertEqual(e.seats[0].remaining, 476)
        XCTAssertEqual(events.filter { if case .dart = $0 { return true }; return false }.count, 3)
        XCTAssertEqual(events.filter { if case .turnEnded = $0 { return true }; return false }.count, 1)
    }

    func testBustRules() {
        let e = engine(40)
        e.register(.triple(20))                      // 40-60 < 0
        XCTAssertEqual(e.records.last?.outcome, .bust)
        XCTAssertEqual(e.seats[0].remaining, 40)
        XCTAssertEqual(e.records.last?.darts.count, 1)

        let f = engine(40)
        f.register(.single(20)); f.register(.single(19))   // rest 1 → bust bij double-out
        XCTAssertEqual(f.records.last?.outcome, .bust)
        XCTAssertEqual(f.seats[0].remaining, 40)

        let g = engine(40)
        g.register(.single(20)); g.register(.single(20))   // 0 maar niet op een double
        XCTAssertEqual(g.records.last?.outcome, .bust)
    }

    func testCheckoutOnDoubleAndBull() {
        let e = engine(40)
        e.register(.double(20))
        XCTAssertEqual(e.phase, .finished)
        XCTAssertEqual(e.winner?.id, a)

        let f = engine(50)
        f.register(.bull)
        XCTAssertEqual(f.phase, .finished)
    }

    func testCorrectionOfCurrentDart() {
        let e = engine()
        e.register(.triple(20))
        e.setCurrentDart(at: 0, to: .single(20))
        XCTAssertEqual(e.liveRemaining, 481)
        e.setCurrentDart(at: 1, to: .single(1))   // toevoegen
        XCTAssertEqual(e.turn.count, 2)
    }

    func testAmendOldTurnReplaysEverything() {
        let e = engine(101)
        e.register(.triple(20)); e.register(.single(1)); e.register(.single(0 + 1)) // Liam 101-62 = 39
        e.nextPlayer()
        e.completeTurnWithMisses()                                                 // Jonas 0
        e.nextPlayer()
        XCTAssertEqual(e.seats[0].remaining, 39)
        // Eerste beurt was eigenlijk T20 T20 S1 → 101-121 = bust
        let first = e.records[0].id
        e.amendTurn(id: first, darts: [.triple(20), .triple(20), .single(1)])
        XCTAssertEqual(e.records[0].outcome, .bust)
        XCTAssertEqual(e.records[0].darts.count, 2, "pijl na bust vervalt")
        XCTAssertEqual(e.seats[0].remaining, 101)
        XCTAssertEqual(e.current, 0)
        XCTAssertEqual(e.phase, .throwing)
    }

    func testAmendCreatesWinner() {
        let e = engine(40)
        e.register(.single(20)); e.register(.single(10)); e.register(.single(5))   // 5 over
        let id = e.records[0].id
        e.amendTurn(id: id, darts: [.single(20), .double(10)])
        XCTAssertEqual(e.phase, .finished)
        XCTAssertEqual(e.winner?.id, a)
    }

    func testAmendRemovesBustAndReopens() {
        let e = engine(60)
        e.register(.single(20)); e.register(.triple(20))       // bust na 2 pijlen
        XCTAssertEqual(e.phase, .awaitingNext)
        let result = e.amendTurn(id: e.records[0].id, darts: [.single(20), .single(20)])
        XCTAssertEqual(result, .reopened(dartsInTurn: 2))
        XCTAssertEqual(e.phase, .throwing)
        XCTAssertEqual(e.liveRemaining, 20)
        e.register(.double(10))
        XCTAssertEqual(e.phase, .finished)
    }

    func testUndo() {
        let e = engine()
        e.register(.single(20)); e.register(.single(20)); e.register(.single(20))
        XCTAssertEqual(e.phase, .awaitingNext)
        XCTAssertEqual(e.undoLastDart(), 2)
        XCTAssertEqual(e.phase, .throwing)
        XCTAssertEqual(e.seats[0].remaining, 501)
        XCTAssertEqual(e.liveRemaining, 461)
    }

    func testAverage() {
        let e = engine()
        e.register(.triple(20)); e.register(.triple(20)); e.register(.triple(20))
        XCTAssertEqual(e.threeDartAverage(for: 0), 180, accuracy: 0.001)
    }

    func testBullOff() {
        let near = DartHit(segment: 25, multiplier: 1, boardPoint: CGPoint(x: 8, y: 3))
        let far = DartHit(segment: 20, multiplier: 1, boardPoint: CGPoint(x: 0, y: 40))
        XCTAssertEqual(BullOff.decide([(a, far), (b, near)]), .winner(b))
        XCTAssertEqual(BullOff.decide([(a, nil), (b, .miss)]), .rethrow([a, b]))
        let almost = DartHit(segment: 25, multiplier: 1, boardPoint: CGPoint(x: 8.3, y: 3))
        XCTAssertEqual(BullOff.decide([(a, almost), (b, near)]), .rethrow([a, b]))
        XCTAssertEqual(BullOff.order([a, b], startingWith: b), [b, a])
    }
}

final class CheckoutTests: XCTestCase {
    private func route(_ r: Int, _ d: Int = 3) -> String? {
        CheckoutCalculator.suggestion(for: r, dartsLeft: d).map(CheckoutCalculator.label)
    }

    func testKnownCheckouts() {
        XCTAssertEqual(route(170), "T20 · T20 · BULL")
        XCTAssertEqual(route(167), "T20 · T19 · BULL")
        XCTAssertEqual(route(160), "T20 · T20 · D20")
        XCTAssertEqual(route(100), "T20 · D20")
        XCTAssertEqual(route(40), "D20")
        XCTAssertEqual(route(50), "BULL")
        XCTAssertEqual(route(2), "D1")
        XCTAssertEqual(route(3), "S1 · D1")
        XCTAssertNil(route(169))
        XCTAssertNil(route(159))
        XCTAssertNil(route(1))
        XCTAssertNil(route(171))
        XCTAssertNil(route(100, 1))
    }

    func testNumberWords() {
        XCTAssertEqual(NumberWords.british(26), "twenty-six")
        XCTAssertEqual(NumberWords.british(60), "sixty")
        XCTAssertEqual(NumberWords.british(120), "one hundred and twenty")
        XCTAssertEqual(NumberWords.british(100), "one hundred")
        XCTAssertEqual(NumberWords.british(501), "five hundred and one")
    }

    func testEverySuggestionIsValid() {
        for r in 2...170 {
            for d in 1...3 {
                guard let s = CheckoutCalculator.suggestion(for: r, dartsLeft: d) else { continue }
                XCTAssertEqual(s.reduce(0) { $0 + $1.score }, r)
                XCTAssertTrue(s.last!.isDouble)
                XCTAssertLessThanOrEqual(s.count, d)
            }
        }
    }
}

final class ImageAnalysisTests: XCTestCase {

    /// Tekent een "pijl" als lijn van (x0,y0) (punt) naar (x1,y1) (flight, dikker).
    private func drawDart(_ img: inout GrayImage, from p0: (Int, Int), to p1: (Int, Int)) {
        let steps = 200
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let x = Double(p0.0) + (Double(p1.0 - p0.0)) * t
            let y = Double(p0.1) + (Double(p1.1 - p0.1)) * t
            let r = t > 0.75 ? 5 : 1
            for dy in -r...r { for dx in -r...r {
                let xi = Int(x) + dx, yi = Int(y) + dy
                if xi >= 0, yi >= 0, xi < img.width, yi < img.height { img[xi, yi] = 20 }
            } }
        }
    }

    func testDetectsDartAndTip() {
        let empty = GrayImage(width: 300, height: 300, fill: 180)
        var withDart = empty
        drawDart(&withDart, from: (150, 200), to: (160, 110))   // punt onderaan, camera onder het bord
        let result = ImageAnalysis.analyzeChange(current: withDart, reference: empty, emptyBoard: empty)
        XCTAssertEqual(result.kind, .dartAdded)
        let tip = ImageAnalysis.locateTip(of: try! XCTUnwrap(result.dartBlob), cameraSide: Vector2D(dx: 0, dy: 1))
        XCTAssertEqual(Double(tip.x), 150, accuracy: 3)
        XCTAssertEqual(Double(tip.y), 201, accuracy: 3)
    }

    func testRemovalAndNoise() {
        let empty = GrayImage(width: 200, height: 200, fill: 180)
        var withDart = empty
        drawDart(&withDart, from: (100, 150), to: (105, 80))
        XCTAssertEqual(ImageAnalysis.analyzeChange(current: empty, reference: withDart, emptyBoard: empty).kind, .dartsRemoved)

        var noisy = empty
        for i in stride(from: 0, to: noisy.pixels.count, by: 97) { noisy.pixels[i] = 120 }
        XCTAssertEqual(ImageAnalysis.analyzeChange(current: noisy, reference: empty, emptyBoard: empty).kind, .none)

        let hand = GrayImage(width: 200, height: 200, fill: 60)
        XCTAssertEqual(ImageAnalysis.analyzeChange(current: hand, reference: empty, emptyBoard: empty).kind, .obstruction)
    }

    func testBoardColorDetection() {
        let w = 200, h = 150
        var px = [UInt8](repeating: 30, count: w * h * 4)
        let cx = 110.0, cy = 70.0
        for y in 0..<h { for x in 0..<w {
            let dx = Double(x) - cx, dy = Double(y) - cy, r = hypot(dx, dy)
            let i = 4 * (y * w + x)
            px[i + 3] = 255
            if r >= 45 && r <= 50 {   // double-ring: rood/groen afwisselend
                let seg = Int((atan2(dy, dx) * 180 / .pi + 369).truncatingRemainder(dividingBy: 360) / 18)
                if seg % 2 == 0 { px[i] = 200; px[i + 1] = 30; px[i + 2] = 30 } else { px[i] = 30; px[i + 1] = 160; px[i + 2] = 60 }
            }
        } }
        let box = try! XCTUnwrap(ImageAnalysis.detectBoard(in: RGBAImage(width: w, height: h, pixels: px)))
        XCTAssertEqual(Double(box.midX), cx + 0.5, accuracy: 2)
        XCTAssertEqual(Double(box.midY), cy + 0.5, accuracy: 2)
        XCTAssertEqual(Double(box.width), 101, accuracy: 4)
    }
}

final class ThrowTrackerTests: XCTestCase {

    private let empty = GrayImage(width: 200, height: 200, fill: 180)

    private func withDarts(_ tips: [(Int, Int)]) -> GrayImage {
        var img = empty
        for (x, y) in tips {
            for t in 0...60 {                       // punt onderaan, flight bovenaan
                let yy = y - t, r = t > 45 ? 4 : 1
                for dy in -r...r { for dx in -r...r { img[x + dx, yy + dy] = 30 } }
            }
        }
        return img
    }

    /// Voert `count` identieke beelden in en verzamelt de events.
    @discardableResult
    private func feed(_ t: ThrowTracker, _ img: GrayImage, _ count: Int, person: Bool? = nil) -> [ThrowTracker.Event] {
        var ev: [ThrowTracker.Event] = []
        for i in 0..<count {
            ev += t.process(motionFrame: img, analysisFrame: { img }, personNearBoard: (i % 6 == 0) ? (person ?? false) : nil)
        }
        return ev
    }

    private func dartTips(_ ev: [ThrowTracker.Event]) -> [CGPoint] {
        ev.compactMap { if case .dart(let p, _, _) = $0 { return p }; return nil }
    }

    private func readyTracker(_ config: ThrowTracker.Config? = nil) -> ThrowTracker {
        var c = config ?? ThrowTracker.Config()
        if config == nil { c.cooldownFrames = 5 }        // tests gooien sneller dan mensen
        c.settleFrames = 8                               // tests voeren 12 beelden per worp
        let t = ThrowTracker(config: c)
        t.cameraSide = Vector2D(dx: 0, dy: 1)
        XCTAssertEqual(feed(t, empty, 30), [.baselineCaptured])
        t.setMode(.game)
        return t
    }

    func testBaselineToleratesLightFlickerButNotShaking() {
        let t = ThrowTracker()
        var flicker = [GrayImage]()
        for i in 0..<30 {                         // een paar pixels flikkeren (licht, blaadjes)
            var img = empty
            for k in 0..<10 { img.pixels[(i * 37 + k * 911) % img.pixels.count] = 60 }
            flicker.append(img)
        }
        var ev: [ThrowTracker.Event] = []
        for img in flicker { ev += t.process(motionFrame: img, analysisFrame: { img }, personNearBoard: nil) }
        XCTAssertEqual(ev, [.baselineCaptured], "kleine flikkering mag")

        let shaky = ThrowTracker()
        var ev2: [ThrowTracker.Event] = []
        for i in 0..<60 {                          // hele beeld verschuift = iPhone in de hand
            var img = empty
            for y in 0..<200 { img[(i * 7) % 200, y] = 20; img[(i * 7 + 1) % 200, y] = 20 }
            ev2 += shaky.process(motionFrame: img, analysisFrame: { img }, personNearBoard: nil)
        }
        XCTAssertTrue(ev2.isEmpty, "trillende camera: geen leeg bord vastleggen")
        shaky.forceBaseline()
        XCTAssertEqual(shaky.process(motionFrame: empty, analysisFrame: { self.empty }, personNearBoard: nil), [.baselineCaptured],
                       "knop 'Nu vastleggen' werkt altijd")
    }

    func testDartDetectedAfterSettle() {
        let t = readyTracker()
        let one = withDarts([(100, 150)])
        let ev = feed(t, one, 12)
        let tips = dartTips(ev)
        XCTAssertEqual(tips.count, 1)
        XCTAssertEqual(Double(tips[0].x), 100.5, accuracy: 2)
        XCTAssertEqual(Double(tips[0].y), 151, accuracy: 2)
        XCTAssertTrue(feed(t, one, 60).isEmpty, "dezelfde pijl niet opnieuw tellen")
    }

    func testIdlePollCatchesDartWithoutMotion() {
        var c = ThrowTracker.Config()
        c.idlePollFrames = 30                            // standaard uit (ghost-bron), hier aan
        c.cooldownFrames = 5
        c.settleFrames = 8
        let t = readyTracker(c)
        feed(t, empty, 5)
        // Simuleer: bewegingsdetectie mist de pijl (motion-beeld blijft leeg), maar het analysebeeld heeft hem.
        let one = withDarts([(80, 120)])
        var ev: [ThrowTracker.Event] = []
        for _ in 0..<40 { ev += t.process(motionFrame: empty, analysisFrame: { one }, personNearBoard: nil) }
        XCTAssertEqual(dartTips(ev).count, 1)
    }

    /// Specificatie: 2 pijlen, speler loopt naar het bord → event met 2 getelde pijlen.
    func testTwoDartsThenPlayerWalksUp() {
        let t = readyTracker()
        feed(t, withDarts([(60, 150)]), 12)
        let two = withDarts([(60, 150), (140, 150)])
        XCTAssertEqual(dartTips(feed(t, two, 12)).count, 1)
        let ev = feed(t, two, 13, person: true)
        XCTAssertEqual(ev, [.playerAtBoard(dartsCounted: 2, wasLocked: false, reason: .person)])
        // Pijlen eruit, persoon weg, stilstand → bord leeg
        let cleared = feed(t, empty, 90, person: false)
        XCTAssertEqual(cleared, [.boardCleared])
        XCTAssertEqual(t.dartsCounted, 0)
    }

    func testThirdDartLocksTurn() {
        let t = readyTracker()
        feed(t, withDarts([(50, 150)]), 12)
        feed(t, withDarts([(50, 150), (100, 150)]), 12)
        feed(t, withDarts([(50, 150), (100, 150), (150, 150)]), 12)
        XCTAssertTrue(t.turnLocked)
        let ev = feed(t, withDarts([(50, 150), (100, 150), (150, 150)]), 13, person: true)
        XCTAssertEqual(ev, [.playerAtBoard(dartsCounted: 3, wasLocked: true, reason: .person)])
    }

    func testRemovingDartsWithoutPersonDetection() {
        let t = readyTracker()
        let one = withDarts([(100, 150)])
        feed(t, one, 12)
        // Alleen een hand trekt de pijl eruit (persoonsdetectie ziet niets).
        let ev = feed(t, empty, 12)
        XCTAssertEqual(ev, [.playerAtBoard(dartsCounted: 1, wasLocked: false, reason: .dartsRemoved)])
        XCTAssertEqual(feed(t, empty, 60), [.boardCleared])
    }

    func testGhostsAreRejected() {
        let t = readyTracker()
        // Zachte, ronde vlek (schaduw) → afgekeurd
        var shadow = empty
        for y in 60..<90 { for x in 60..<90 { shadow[x, y] = 150 } }     // zachte, ronde vlek
        let ev = feed(t, shadow, 12)
        XCTAssertTrue(dartTips(ev).isEmpty, "schaduw is geen worp")
        XCTAssertTrue(ev.contains { if case .rejected = $0 { return true }; return false })
        // Echte pijl daarna (schaduw blijft liggen) wordt wel geteld
        var dart = withDarts([(150, 170)])
        for y in 60..<90 { for x in 60..<90 { dart[x, y] = 150 } }
        XCTAssertEqual(dartTips(feed(t, dart, 12)).count, 1)
    }

    /// Camera recht voor het bord: de pijl lijkt een kruisje (flight van voren). Vroeger "niet langwerpig" → ghost.
    func testFrontalDartIsCountedAsDoubtful() {
        let t = readyTracker()
        var cross = empty
        for d in -14...14 { for w in -2...2 { cross[100 + d, 120 + w] = 30; cross[100 + w, 120 + d] = 30 } }
        let ev = feed(t, cross, 12)
        let darts = ev.compactMap { e -> Bool? in if case .dart(_, let doubtful, _) = e { return doubtful }; return nil }
        XCTAssertEqual(darts, [true], "telt, maar als twijfel (model mag beslissen): \(ev)")
        t.retractLastDart()
        XCTAssertEqual(t.dartsCounted, 0)
    }

    func testCooldownBlocksDoubleTrigger() {
        let t = readyTracker(ThrowTracker.Config())      // standaard cooldown (36 frames)
        XCTAssertEqual(dartTips(feed(t, withDarts([(50, 150)]), 12)).count, 1)
        let ev = feed(t, withDarts([(50, 150), (120, 150)]), 12)   // 12 frames later = te snel
        XCTAssertTrue(dartTips(ev).isEmpty)
        XCTAssertTrue(ev.contains(.rejected(reason: "binnen cooldown")))
    }

    func testLongMotionIsPersonNotThrow() {
        let t = readyTracker()
        // 60 frames lang telkens een beetje beweging (iemand die rondloopt aan de rand)
        var ev: [ThrowTracker.Event] = []
        for i in 0..<60 {
            var img = empty
            for k in 0..<30 { img[(i * 3 + k) % 200, 5] = 20 }
            ev += t.process(motionFrame: img, analysisFrame: { img }, personNearBoard: nil)
        }
        XCTAssertTrue(dartTips(ev).isEmpty)
        XCTAssertTrue(ev.contains { if case .playerAtBoard(_, _, .obstruction) = $0 { return true }; return false })
    }

    func testPersonLeavesWithDartsStillInBoard() {
        let t = readyTracker()
        let one = withDarts([(100, 150)])
        feed(t, one, 12)
        XCTAssertEqual(feed(t, one, 13, person: true), [.playerAtBoard(dartsCounted: 1, wasLocked: false, reason: .person)])
        XCTAssertEqual(feed(t, one, 90, person: false), [.personLeft(dartsCounted: 1)], "pijl zit er nog: geen 'bord leeg'")
    }

    func testManualNextKeepsBoardLockedUntilCleared() {
        let t = readyTracker()
        let three = withDarts([(50, 150), (100, 150), (150, 150)])
        feed(t, withDarts([(50, 150)]), 12)
        feed(t, withDarts([(50, 150), (100, 150)]), 12)
        feed(t, three, 12)
        t.manualNext()                                   // gebruiker drukt "Volgende" met pijlen nog in het bord
        let ev = feed(t, three, 13, person: true)
        XCTAssertEqual(ev, [.playerAtBoard(dartsCounted: 0, wasLocked: true, reason: .person)])
        XCTAssertEqual(feed(t, empty, 90, person: false), [.boardCleared])
        XCTAssertFalse(t.turnLocked)
        XCTAssertEqual(dartTips(feed(t, withDarts([(90, 150)]), 12)).count, 1, "nieuwe speler wordt gewoon gedetecteerd")
    }

    func testBullOffDoesNotLock() {
        let t = readyTracker()
        t.setMode(.bullOff)
        feed(t, withDarts([(100, 110)]), 12)
        let ev = feed(t, withDarts([(100, 110), (120, 120)]), 12)
        XCTAssertEqual(dartTips(ev).count, 1)
        XCTAssertFalse(t.turnLocked)
    }
}

final class CameraMathTests: XCTestCase {
    func testZoomFillsFrameAndKeepsBoardInside() {
        let size = CGSize(width: 1080, height: 1920)
        // Klein bord in het midden → flink inzoomen
        let k = CameraMath.zoomFactor(forBoardBox: CGRect(x: 440, y: 860, width: 200, height: 200), imageSize: size)
        XCTAssertEqual(Double(k), 0.95 * 1080 / (200 * 1.33), accuracy: 0.06)
        // Bord uit het midden → minder zoom zodat het in beeld blijft
        let k2 = CameraMath.zoomFactor(forBoardBox: CGRect(x: 80, y: 860, width: 200, height: 200), imageSize: size)
        XCTAssertLessThan(Double(k2), Double(k))
        XCTAssertGreaterThanOrEqual(Double(k2), 1)
        // Bord vult al het beeld → niet zoomen
        XCTAssertEqual(Double(CameraMath.zoomFactor(forBoardBox: CGRect(x: 100, y: 500, width: 880, height: 880), imageSize: size)), 1, accuracy: 0.001)
    }
}

final class YoloInterpreterTests: XCTestCase {

    /// Detecties zoals het Dart Sense-model ze geeft (klassen 20, 6, 3, 11, 9, 15).
    private func modelDetections(_ toImage: (CGPoint) -> CGPoint) -> [Detection] {
        let labels = YoloInterpreter.Labels().calibration
        return labels.map { name, deg in
            let a = deg * .pi / 180
            return Detection(label: name, point: toImage(CGPoint(x: 170 * cos(a), y: 170 * sin(a))), confidence: 0.9)
        }
    }

    func testCalibrationFromDetections() {
        // Schuin perspectief
        let toImage = { (p: CGPoint) -> CGPoint in
            let x = Double(p.x), y = Double(p.y), w = 1 + y * 0.001
            return CGPoint(x: 400 + x * 2 / w, y: 500 - y * 1.7 / w)
        }
        var dets = modelDetections(toImage)
        dets.append(Detection(label: "20", point: CGPoint(x: 1, y: 1), confidence: 0.6)) // zwakkere dubbele
        dets.append(Detection(label: "6", point: CGPoint(x: 5, y: 5), confidence: 0.3))  // te onzeker
        let pts = try! XCTUnwrap(YoloInterpreter.calibrationPoints(dets))
        let cal = try! XCTUnwrap(BoardCalibration(imagePoints: pts, imageSize: CGSize(width: 1000, height: 1000)))
        for (mm, label) in [(CGPoint(x: 0, y: 103), "T20"), (CGPoint(x: 166, y: 0), "D6"), (CGPoint(x: -3, y: 2), "BULL")] {
            XCTAssertEqual(BoardGeometry.hit(at: cal.toBoard.apply(toImage(mm))).shortLabel, label)
        }
        // Twee punten weg ("20" en "3"): met de 4 overige lukt het nog steeds
        let partial = dets.filter { $0.label != "20" && $0.label != "3" }
        let pts2 = try! XCTUnwrap(YoloInterpreter.calibrationPoints(partial))
        let cal2 = try! XCTUnwrap(BoardCalibration(imagePoints: pts2, imageSize: CGSize(width: 1000, height: 1000)))
        XCTAssertEqual(BoardGeometry.hit(at: cal2.toBoard.apply(toImage(CGPoint(x: 0, y: 103)))).shortLabel, "T20")
        XCTAssertNil(YoloInterpreter.calibrationPoints(Array(partial.filter { $0.confidence > 0.5 }.prefix(3))), "minder dan 4 punten")
    }

    func testLeastSquaresHomographyWithNoise() {
        let truth = Homography(matrix: [1.8, 0.2, 500, -0.1, -1.6, 520, 0.0004, 0.0009, 1])
        let board = (0..<12).map { i -> CGPoint in let a = Double(i) * 30 * .pi / 180; return CGPoint(x: 170 * cos(a), y: 170 * sin(a)) }
        let image = board.enumerated().map { i, p in
            let q = truth.apply(p); return CGPoint(x: Double(q.x) + (i % 2 == 0 ? 0.8 : -0.8), y: Double(q.y) + (i % 3 == 0 ? 0.6 : -0.4))
        }
        let h = try! XCTUnwrap(Homography(leastSquaresFrom: board, to: image))
        let c = h.apply(CGPoint(x: 0, y: 103)), t = truth.apply(CGPoint(x: 0, y: 103))
        XCTAssertLessThan(hypot(Double(c.x - t.x), Double(c.y - t.y)), 1.0)
    }

    /// Echte YOLO-uitvoer op een foto van Liams bord: punt 8|11 werd als "15" gelabeld.
    func testCalibrationSurvivesSwappedLabel() {
        let dets = [
            Detection(label: "15", point: CGPoint(x: 327, y: 1297), confidence: 0.77),   // eigenlijk 8|11!
            Detection(label: "15", point: CGPoint(x: 1571, y: 1310), confidence: 0.71),
            Detection(label: "20", point: CGPoint(x: 885, y: 232), confidence: 0.79),
            Detection(label: "3", point: CGPoint(x: 849, y: 1699), confidence: 0.23),
            Detection(label: "3", point: CGPoint(x: 1062, y: 1697), confidence: 0.41),
            Detection(label: "6", point: CGPoint(x: 1647, y: 877), confidence: 0.86),
            Detection(label: "9", point: CGPoint(x: 348, y: 610), confidence: 0.62),
        ]
        let pts = try! XCTUnwrap(YoloInterpreter.calibrationPoints(dets))
        // Echte posities (verfijnd op 180 randpunten van de foto, fout 1 px): 5|20, 13|6, 17|3, 8|11
        let expected = [CGPoint(x: 887, y: 232), CGPoint(x: 1649, y: 876), CGPoint(x: 1064, y: 1699), CGPoint(x: 258, y: 1071)]
        for (p, e) in zip(pts, expected) {
            XCTAssertLessThan(hypot(Double(p.x - e.x), Double(p.y - e.y)), 25, "\(p) vs \(e)")
        }
        // Zonder RANSAC (alle punten gemiddeld) lag het 8|11-punt >200 px verkeerd.
    }

    /// Uit Liams testvideo: de geschatte punt lag aan de flight-kant; een ander (fout) punt lag dichterbij.
    func testNewDartPicksPointOnBlob() {
        let id = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let onBlob = Detection(label: "dart", point: CGPoint(x: 40, y: 60), confidence: 0.8)     // echte punt, op de vlek
        let decoy = Detection(label: "dart", point: CGPoint(x: 10, y: 140), confidence: 0.6)     // vals, dichter bij de hint
        let region = CGRect(x: 30, y: 50, width: 40, height: 60)                                   // vlek van de nieuwe pijl
        let hint = CGPoint(x: 15, y: 120)                                                          // schatting aan de verkeerde kant
        XCTAssertEqual(YoloInterpreter.newDartPoint(candidates: [onBlob, decoy], known: [], hint: hint, toBoard: id),
                       CGPoint(x: 10, y: 140), "oude methode kiest het foute punt")
        XCTAssertEqual(YoloInterpreter.newDartPoint(candidates: [onBlob, decoy], known: [], hint: hint, toBoard: id,
                                                    region: region, regionMarginPx: 25), CGPoint(x: 40, y: 60))
        XCTAssertNil(YoloInterpreter.newDartPoint(candidates: [decoy], known: [], hint: hint, toBoard: id,
                                                  region: region, regionMarginPx: 25), "niets op de vlek → terugval")
    }

    func testCalibrationPointsMatchDeepDartsLayout() {
        // 5|20 bovenaan-links van de 20, 13|6 rechts, 17|3 onder, 8|11 links
        let p = BoardGeometry.calibrationPointsMM
        XCTAssertEqual(BoardGeometry.hit(at: CGPoint(x: Double(p[0].x) * 0.9 - 1, y: Double(p[0].y) * 0.9)).segment, 5)
        XCTAssertEqual(BoardGeometry.hit(at: CGPoint(x: Double(p[0].x) * 0.9 + 3, y: Double(p[0].y) * 0.9)).segment, 20)
        XCTAssertEqual(BoardGeometry.hit(at: CGPoint(x: Double(p[1].x) * 0.9, y: Double(p[1].y) * 0.9 + 3)).segment, 13)
        XCTAssertEqual(BoardGeometry.hit(at: CGPoint(x: Double(p[2].x) * 0.9 - 3, y: Double(p[2].y) * 0.9)).segment, 3)
        XCTAssertEqual(BoardGeometry.hit(at: CGPoint(x: Double(p[3].x) * 0.9, y: Double(p[3].y) * 0.9 + 3)).segment, 11)
    }

    func testNewDartSelection() {
        let identity = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])   // beeld = mm, voor de test
        let old = Detection(label: "dart", point: CGPoint(x: 0, y: 103), confidence: 0.9)
        let new = Detection(label: "dart", point: CGPoint(x: 60, y: 10), confidence: 0.8)
        let far = Detection(label: "dart", point: CGPoint(x: -120, y: -40), confidence: 0.7)
        let tips = YoloInterpreter.dartTips([old, new, far, Detection(label: "dart", point: CGPoint(x: 61, y: 11), confidence: 0.5)])
        XCTAssertEqual(tips.count, 3, "dubbele detectie samengevoegd")
        let p = YoloInterpreter.newDartPoint(candidates: tips, known: [CGPoint(x: 1, y: 102)],
                                             hint: CGPoint(x: 55, y: 20), toBoard: identity)
        XCTAssertEqual(Double(try! XCTUnwrap(p).x), 60, accuracy: 0.01)
        XCTAssertNil(YoloInterpreter.newDartPoint(candidates: tips, known: [], hint: CGPoint(x: 0, y: -150), toBoard: identity),
                     "YOLO zag de nieuwe pijl niet → terugvallen op frame-difference")
    }
}

final class LearningTests: XCTestCase {

    func testNearestPointInRegion() {
        // Detectie net onder de triple-ring (S20), gecorrigeerd naar T20 → punt in T20
        let p = CorrectionLearner.nearestPoint(in: .triple(20), to: CGPoint(x: 0, y: 96))
        XCTAssertEqual(BoardGeometry.hit(at: p).shortLabel, "T20")
        XCTAssertEqual(Double(p.y), 101, accuracy: 0.01)
        // Verkeerd segment: in T19 gedetecteerd, eigenlijk T3 (buur)
        let q = CorrectionLearner.nearestPoint(in: .triple(3), to: CGPoint(x: -20, y: -101))
        XCTAssertEqual(BoardGeometry.hit(at: q).shortLabel, "T3")
        XCTAssertEqual(BoardGeometry.hit(at: CorrectionLearner.nearestPoint(in: .miss, to: CGPoint(x: 0, y: 165))).shortLabel, "MIS")
        XCTAssertEqual(BoardGeometry.hit(at: CorrectionLearner.nearestPoint(in: .bull, to: CGPoint(x: 9, y: 0))).shortLabel, "BULL")
        XCTAssertEqual(BoardGeometry.hit(at: CorrectionLearner.nearestPoint(in: .single(20), to: CGPoint(x: 0, y: 103))).shortLabel, "S20")
    }

    /// Camera meet systematisch 6 mm te laag. Na een paar correcties moet de app dat zelf rechtzetten.
    func testLearnsSystematicOffset() {
        var learner = CorrectionLearner()
        let bias = CGPoint(x: 0, y: -6)
        func detect(_ truth: CGPoint) -> CGPoint { CGPoint(x: truth.x + bias.x, y: truth.y + bias.y) }

        // Voor het leren: T20 op y=100 wordt gelezen als S20
        let truth = CGPoint(x: 1, y: 100)
        XCTAssertEqual(BoardGeometry.hit(at: learner.apply(detect(truth))).shortLabel, "S20")

        var fixedAfter = -1
        for i in 1...10 {
            let t = CGPoint(x: Double(i % 3) - 1, y: 100 + Double(i % 2))
            let raw = detect(t)
            let shown = learner.apply(raw)
            if BoardGeometry.hit(at: shown).shortLabel != "T20" {
                learner.observeCorrected(raw: raw, shown: shown, correct: .triple(20))
            } else {
                learner.observeConfirmed(raw: raw, shown: shown)
                if fixedAfter < 0 { fixedAfter = i }
            }
        }
        XCTAssertGreaterThan(fixedAfter, 0, "leert de afwijking")
        XCTAssertLessThanOrEqual(fixedAfter, 4, "snel genoeg")
        XCTAssertEqual(BoardGeometry.hit(at: learner.apply(detect(truth))).shortLabel, "T20")
        // Ver weg op het bord (T3) werkt de globale correctie ook, maar begrensd
        let c = learner.correction(at: CGPoint(x: 0, y: -103))
        XCTAssertGreaterThan(c.dy, 0.5)
        XCTAssertLessThanOrEqual(hypot(c.dx, c.dy), learner.maxShiftMM + 1e-9)
    }

    func testNoLearningMeansNoShift() {
        let l = CorrectionLearner()
        XCTAssertEqual(l.apply(CGPoint(x: 12, y: 34)), CGPoint(x: 12, y: 34))
    }

    func testYoloLabelsFromSample() {
        // Camera recht voor het bord: 1 mm = 2 px, midden op (500, 500) in een beeld van 1000×1000
        let toImage = Homography(matrix: [2, 0, 500, 0, -2, 500, 0, 0, 1])
        let a = UUID(), b = UUID(), c = UUID()
        let sample = TrainingSample(width: 800, height: 800, roi: [100, 100, 800, 800],
                                    boardToImage: toImage.m, dartIDs: [a, b, c])
        let labels: [UUID: DartLabel] = [a: .point(x: 0, y: 103, approximate: false),
                                         b: .point(x: 0, y: 0, approximate: true),
                                         c: .notADart]
        let lines = try! XCTUnwrap(TrainingLabelMaker.yoloLines(for: sample, labels: labels))
        XCTAssertEqual(lines.count, 6 + 2, "6 kalibratiepunten + 2 echte pijlen")
        XCTAssertTrue(lines.contains("4 0.500000 0.242500 0.025000 0.025000"), "T20-pijl")
        XCTAssertTrue(lines.contains("4 0.500000 0.500000 0.025000 0.025000"), "bull")
        // Kalibratiepunt "20" (5|20, 99°) ligt boven, iets links van het midden
        let cal20 = lines.first { $0.hasPrefix("0 ") }!.split(separator: " ").map { Double($0)! }
        XCTAssertLessThan(cal20[1], 0.5); XCTAssertLessThan(cal20[2], 0.1)
        XCTAssertNil(TrainingLabelMaker.yoloLines(for: sample, labels: [a: .notADart]), "onvolledig gelabeld")
    }

    func testTrainingModeLabels() {
        let toImage = Homography(matrix: [2, 0, 500, 0, -2, 500, 0, 0, 1])
        let lines = TrainingLabelMaker.yoloLines(roi: [100, 100, 800, 800], boardToImage: toImage.m,
                                                 dartsMM: [CGPoint(x: 0, y: 103), CGPoint(x: 0, y: 300)])  // 2e buiten beeld
        XCTAssertEqual(lines.filter { $0.hasPrefix("4 ") }, ["4 0.500000 0.242500 0.025000 0.025000"])
        XCTAssertEqual(lines.count, 7)
        let yaml = TrainingLabelMaker.datasetYAML(imageDirs: ["positives/images", "needs_retraining/images"])
        XCTAssertTrue(yaml.contains("  - needs_retraining/images") && yaml.contains("4: 'dart'"))
    }

    func testLearnerIsCodable() {
        var l = CorrectionLearner()
        l.observeCorrected(raw: CGPoint(x: 0, y: 95), shown: CGPoint(x: 0, y: 95), correct: .triple(20))
        let data = try! JSONEncoder().encode(l)
        XCTAssertEqual(try! JSONDecoder().decode(CorrectionLearner.self, from: data), l)
    }
}

final class CallerScriptTests: XCTestCase {

    private func isValidXML(_ s: String) -> Bool {
        XMLParser(data: s.data(using: .utf8)!).parse()
    }

    func testAllLinesAreValidSSML() {
        var lines: [CallerLine] = []
        for style in CallerStyle.allCases {
            for total in 0...180 {
                lines += CallerScript.turn(total: total, outcome: .scored, won: false, remaining: 141,
                                           name: "Liam & <Jonas>", style: style)
            }
            lines += CallerScript.turn(total: 0, outcome: .bust, won: false, remaining: 40, name: "Liam", style: style)
            lines += CallerScript.turn(total: 40, outcome: .checkout, won: true, remaining: 0, name: "Liam", style: style)
            lines.append(CallerScript.firstThrower("O'Brien & Co", style: style))
            lines.append(CallerScript.dart(.triple(20), multiplierWord: "Treble", style: style))
            lines.append(CallerScript.correction(style: style))
        }
        for l in lines { XCTAssertTrue(isValidXML(l.ssml), "ongeldige SSML: \(l.ssml)") }
    }

    func testTVCallerContent() {
        let t180 = CallerScript.turn(total: 180, outcome: .scored, won: false, remaining: 321, name: "Liam", style: .tv)
        XCTAssertEqual(t180.count, 1, "321 over: geen 'you require'")
        XCTAssertTrue(t180[0].ssml.contains(#"<prosody rate="68%" pitch="+22%" volume="x-loud">eighty!"#), "enkel 'eighty' uitgerekt")
        XCTAssertTrue(t180[0].ssml.contains(#"<prosody rate="110%" pitch="+8%" volume="x-loud">One hundred and"#), "rest vlot")
        let fast = CallerScript.turn(total: 180, outcome: .scored, won: false, remaining: 321, name: nil, style: .tv, tempo: 1.2)
        XCTAssertTrue(fast[0].ssml.contains(#"rate="82%""#), "tempo-schuif werkt (68 × 1,2)")
        XCTAssertEqual(CallerScript.pct(30, 1), "40%", "ondergrens")
        XCTAssertEqual(CallerScript.pct(150, 1.5), "200%", "bovengrens")
        XCTAssertEqual(t180[0].plain, "One hundred and eighty!")

        let t = CallerScript.turn(total: 60, outcome: .scored, won: false, remaining: 40, name: "Liam", style: .tv)
        XCTAssertEqual(t.map(\.plain), ["sixty", "Liam, you require forty"])

        let ton = CallerScript.scoreLine(140, style: .tv)
        XCTAssertTrue(ton.ssml.contains("forty!"))
        XCTAssertEqual(ton.plain, "one hundred and forty!")

        let won = CallerScript.turn(total: 40, outcome: .checkout, won: true, remaining: 0, name: "Liam", style: .tv)
        XCTAssertEqual(won.map(\.plain), ["Game shot, and the match!"])

        let std = CallerScript.turn(total: 26, outcome: .scored, won: false, remaining: 101, name: "Liam", style: .standard)
        XCTAssertEqual(std.map(\.plain), ["twenty-six", "You require one hundred and one"])
        XCTAssertEqual(CallerScript.dart(.outerBull, multiplierWord: "Triple", style: .tv).plain, "Outer Bull")
    }
}

final class ShakeFilterTests: XCTestCase {

    /// Bord-achtige textuur (sectoren + ringen), zodat verschuivingen meetbaar zijn zoals bij een echt bord.
    private let board: GrayImage = {
        var img = GrayImage(width: 200, height: 200, fill: 0)
        for y in 0..<200 { for x in 0..<200 {
            let dx = Double(x - 100), dy = Double(y - 100)
            let a = atan2(dy, dx), r = hypot(dx, dy)
            let sector = Int((a + .pi) / (2 * .pi) * 20) % 2
            let ring = Int(r / 12) % 2
            img[x, y] = UInt8(60 + 90 * sector + 40 * ring)
        } }
        return img
    }()

    private func dart(on base: GrayImage, tip: (Int, Int)) -> GrayImage {
        var img = base
        for t in 0...50 {
            let r = t > 38 ? 3 : 1
            for dy in -r...r { for dx in -r...r { img[tip.0 + dx, tip.1 - t + dy] = 255 } }
        }
        return img
    }

    private func tracker() -> ThrowTracker {
        var c = ThrowTracker.Config()
        c.cooldownFrames = 5
        c.settleFrames = 8
        let t = ThrowTracker(config: c)
        t.cameraSide = Vector2D(dx: 0, dy: 1)
        for _ in 0..<30 { _ = t.process(motionFrame: board, analysisFrame: { self.board }, personNearBoard: nil) }
        XCTAssertTrue(t.hasBaseline)
        t.setMode(.game)
        return t
    }

    private func feed(_ t: ThrowTracker, _ img: GrayImage, _ n: Int) -> [ThrowTracker.Event] {
        (0..<n).flatMap { _ in t.process(motionFrame: img, analysisFrame: { img }, personNearBoard: nil) }
    }

    func testEstimateShiftOnBoard() {
        let moved = GlobalMotion.shifted(board, by: .init(dx: 3, dy: -2))
        XCTAssertEqual(GlobalMotion.estimateShift(from: board, to: moved, maxShift: 5), .init(dx: 3, dy: -2))
        XCTAssertEqual(GlobalMotion.changedPixelCount(board, moved, shift: .init(dx: 3, dy: -2), threshold: 18), 0,
                       "na compensatie: geen beweging meer")
        // Een pijl erbij is LOKALE beweging: geen verschuiving
        XCTAssertEqual(GlobalMotion.estimateShift(from: board, to: dart(on: board, tip: (120, 150)), maxShift: 5), .zero)
    }

    /// Statief trilt (hele beeld ±2 px heen en weer) zonder aanraking-melding → geen worp, geen obstructie.
    func testDefaultSettleIs300ms() {
        XCTAssertEqual(ThrowTracker.Config().settleFrames, 18, "18 frames ≈ 300 ms bij 60 fps")
    }

    /// Uit Liams video: statief zakt langzaam een halve pixel → mag geen "verandering" op alle draden geven.
    func testSubpixelDriftIsCompensated() {
        let drifted = GlobalMotion.shifted(board, by: Vector2D(dx: 0.6, dy: -0.4))
        let est = GlobalMotion.estimateSubpixelShift(from: board, to: drifted, maxShift: 5)
        XCTAssertEqual(est.dx, 0.6, accuracy: 0.15)
        XCTAssertEqual(est.dy, -0.4, accuracy: 0.15)
        let t = tracker()
        var withDart = dart(on: drifted, tip: (120, 150))
        let ev = feed(t, drifted, 3) + feed(t, withDart, 14)
        let tips = ev.compactMap { if case .dart(let p, _, _) = $0 { return p }; return nil }
        XCTAssertEqual(tips.count, 1, "\(ev)")
        XCTAssertEqual(Double(tips[0].x), 120.5, accuracy: 2.5)
        withDart = drifted   // (ongebruikt)
    }

    func testTripodShakeIsIgnored() {
        let t = tracker()
        var ev: [ThrowTracker.Event] = []
        for i in 0..<30 {
            let s = GlobalMotion.Shift(dx: [2, -1, 1, -2, 0][i % 5], dy: [1, 0, -2, 1, -1][i % 5])
            ev += feed(t, GlobalMotion.shifted(board, by: s), 1)
        }
        ev += feed(t, board, 30)
        XCTAssertTrue(ev.isEmpty, "trilling mag niets triggeren: \(ev)")
    }

    /// Statief blijft na de tik 2 px verschoven staan → pijl daarna wordt correct gevonden,
    /// en de punt wordt teruggerekend naar de positie bij kalibratie.
    func testPermanentShiftIsCompensated() {
        let t = tracker()
        let shift = GlobalMotion.Shift(dx: 2, dy: 1)
        let shiftedBoard = GlobalMotion.shifted(board, by: shift)
        XCTAssertTrue(feed(t, shiftedBoard, 30).isEmpty)
        // pijl met punt op (120, 150) in de ORIGINELE positie → in het verschoven beeld op (122, 151)
        let withDart = dart(on: shiftedBoard, tip: (122, 151))
        let ev = feed(t, withDart, 14)
        let tips = ev.compactMap { if case .dart(let p, _, _) = $0 { return p }; return nil }
        XCTAssertEqual(tips.count, 1, "\(ev)")
        XCTAssertEqual(Double(tips[0].x), 120.5, accuracy: 2)
        XCTAssertEqual(Double(tips[0].y), 151, accuracy: 2)
        XCTAssertEqual(t.poseOffset.dx, 2, accuracy: 0.3)
        XCTAssertEqual(t.poseOffset.dy, 1, accuracy: 0.3)
    }

    /// Tijdens aanraking + lockout: ook een grote, lokale verandering (hand/schaduw van de arm) telt niet.
    /// Bug uit de praktijk: na een correctie kwam het "losgelaten"-signaal soms niet → detectie hing vast.
    func testLostTouchEndDoesNotBlockForever() {
        let t = tracker()
        t.touchBegan()                                   // touchEnded komt nooit
        XCTAssertTrue(feed(t, board, 60).isEmpty)
        XCTAssertTrue(t.isInTouchLockout, "eerst nog geblokkeerd")
        XCTAssertTrue(feed(t, board, 90).isEmpty)        // > 2 s + lockout
        XCTAssertFalse(t.isInTouchLockout, "na max. 2 s automatisch vrij")
        let ev = feed(t, dart(on: board, tip: (120, 150)), 14)
        XCTAssertEqual(ev.filter { if case .dart = $0 { return true }; return false }.count, 1, "pijl wordt weer herkend")
        t.touchEnded(); t.touchEnded()                    // dubbel gemeld: geen nieuwe lockout
        XCTAssertFalse(t.isInTouchLockout)
    }

    func testTouchLockout() {
        let t = tracker()
        t.touchBegan()
        var blocked = board
        for y in 20..<180 { for x in 20..<60 { blocked[x, y] = 20 } }       // arm/schaduw vlak bij de gsm
        XCTAssertTrue(feed(t, blocked, 5).isEmpty, "tijdens aanraking niets")
        t.touchEnded()
        XCTAssertTrue(t.isInTouchLockout)
        XCTAssertTrue(feed(t, board, 10).isEmpty, "binnen de lockout niets")
        XCTAssertTrue(feed(t, board, 20).isEmpty)
        XCTAssertFalse(t.isInTouchLockout, "lockout voorbij na ±21 frames")
        // Daarna werkt alles weer normaal
        let ev = feed(t, dart(on: board, tip: (120, 150)), 14)
        XCTAssertEqual(ev.filter { if case .dart = $0 { return true }; return false }.count, 1)
    }
}

final class AutoCalibrationTests: XCTestCase {

    /// Ware projectie mm → beeld (schuin van onder, licht gedraaid) voor een 420×420 testbeeld.
    private func truth(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y), w = 1 + y * 0.0011 + x * 0.0003
        let rx = x * cos(0.05) - y * sin(0.05), ry = x * sin(0.05) + y * cos(0.05)
        return CGPoint(x: 210 + rx * 0.95 / w, y: 205 - ry * 0.88 / w)
    }

    /// Bord tekenen: elke pixel terugrekenen naar mm en de kleur van dat vak geven.
    private func render() -> RGBAImage {
        let W = 420, Hh = 420
        let H = Homography(from: BoardGeometry.calibrationPointsMM, to: BoardGeometry.calibrationPointsMM.map(truth))!
        let inv = H.inverse!
        var px = [UInt8](repeating: 0, count: W * Hh * 4)
        for y in 0..<Hh { for x in 0..<W {
            let mm = inv.apply(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            let r = hypot(Double(mm.x), Double(mm.y))
            var c: (UInt8, UInt8, UInt8) = (150, 120, 90)                       // houten muur
            if r <= 225 { c = (25, 25, 25) }                                     // nummerring
            if r <= 170 {
                let hit = BoardGeometry.hit(at: mm)
                let i = BoardGeometry.order.firstIndex(of: hit.segment) ?? 0
                let even = i % 2 == 0
                switch (hit.segment, hit.multiplier) {
                case (25, 2): c = (200, 40, 40)
                case (25, 1): c = (40, 140, 60)
                case (_, 2), (_, 3): c = even ? (200, 40, 40) : (40, 140, 60)
                default: c = even ? (30, 30, 30) : (225, 215, 190)
                }
            }
            let i = 4 * (y * W + x)
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
        } }
        return RGBAImage(width: W, height: Hh, pixels: px)
    }

    func testRefinesSloppyCalibration() {
        let img = render()
        let exact = BoardGeometry.calibrationPointsMM.map(truth)
        // Slordig aangetikt / ruw geschat: elk punt 5–8 px ernaast
        let offsets = [(6.0, -5.0), (-7.0, 4.0), (5.0, 7.0), (-6.0, -6.0)]
        let rough = zip(exact, offsets).map { CGPoint(x: Double($0.x) + $1.0, y: Double($0.y) + $1.1) }
        let roughErr = zip(rough, exact).map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }.max()!

        let res = try! XCTUnwrap(BoardRefiner.refine(image: img, rough: rough, imageSize: CGSize(width: 420, height: 420)))
        let err = zip(res.points, exact).map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }.max()!
        XCTAssertGreaterThanOrEqual(res.edgePoints, 40)
        XCTAssertLessThan(err, 1.5, "verfijnd: \(err) px (ruw: \(roughErr) px)")
        XCTAssertLessThan(try! XCTUnwrap(res.bullOffsetMM), 2.0, "bull klopt met de kalibratie")
        // Scoren met de verfijnde kalibratie: een punt vlak bij de treble-rand wordt nu juist geteld
        let cal = try! XCTUnwrap(BoardCalibration(imagePoints: res.points, imageSize: CGSize(width: 420, height: 420)))
        for (mm, label) in [(CGPoint(x: 0, y: 100.5), "T20"), (CGPoint(x: 164, y: 1), "D6"), (CGPoint(x: -1, y: -105.5), "T3")] {
            XCTAssertEqual(BoardGeometry.hit(at: cal.toBoard.apply(truth(mm))).shortLabel, label)
        }
    }

    func testRefuseWhenNoBoard() {
        let gray = RGBAImage(width: 200, height: 200, pixels: [UInt8](repeating: 128, count: 200 * 200 * 4))
        let rough = BoardGeometry.calibrationPointsMM.map { CGPoint(x: 100 + Double($0.x) * 0.5, y: 100 - Double($0.y) * 0.5) }
        XCTAssertNil(BoardRefiner.refine(image: gray, rough: rough, imageSize: CGSize(width: 200, height: 200)))
    }

    func testConsensusThreeFrames() {
        var c = DetectionConsensus()
        XCTAssertNil(c.add([CGPoint(x: 100, y: 100), CGPoint(x: 40, y: 40)]))
        XCTAssertNil(c.add([CGPoint(x: 102, y: 101)]))
        let p = try! XCTUnwrap(c.add([CGPoint(x: 101, y: 99)]))
        XCTAssertEqual(Double(p.x), 101, accuracy: 0.01)

        var hand = DetectionConsensus()                       // hand/schaduw: springt rond
        _ = hand.add([CGPoint(x: 50, y: 50)])
        _ = hand.add([CGPoint(x: 70, y: 52)])
        XCTAssertNil(hand.add([CGPoint(x: 90, y: 55)]))
        _ = hand.add([]); _ = hand.add([]); _ = hand.add([])
        XCTAssertTrue(hand.isExhausted)
    }
}
