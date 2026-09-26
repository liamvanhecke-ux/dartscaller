import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Beslist per camerabeeld wat er gebeurt: pijl geland, speler bij het bord, bord leeg.
/// Bevat GEEN camera- of Vision-code: de pipeline voert beelden en de uitkomst van
/// persoonsdetectie aan. Daardoor volledig te testen met gesimuleerde beelden.
final class ThrowTracker {

    enum Mode: Equatable { case off, game, bullOff }

    enum AtBoardReason: Equatable {
        /// Persoonsdetectie zag iemand bij het bord.
        case person
        /// Pijlen verdwenen uit het bord (bv. alleen een hand in beeld).
        case dartsRemoved
        /// Groot deel van het bord afgedekt.
        case obstruction
    }

    enum Event: Equatable {
        /// Leeg bord vastgelegd: klaar om te spelen.
        case baselineCaptured
        /// Nieuwe pijl. Punt in coördinaten van het analysebeeld.
        case dart(tip: CGPoint)
        /// Speler (of hand) bij het bord.
        /// `dartsCounted`: pijlen die in deze beurt gezien zijn.
        /// `wasLocked`: beurt was al dicht (3 pijlen / bust / wachten op leeg bord).
        case playerAtBoard(dartsCounted: Int, wasLocked: Bool, reason: AtBoardReason)
        /// Speler weg en beeld stabiel: pijlen zijn opgehaald.
        case boardCleared
    }

    struct Config {
        /// Grijsverschil per pixel dat als beweging telt.
        var motionPixelThreshold = 18
        /// Zoveel pixels veranderd tussen twee beelden = beweging.
        var motionMinPixels = 3
        /// Voor het vastleggen van het lege bord: kleine lichtflikkering (buiten, doorschijnend dak) toelaten.
        var baselineMaxMovingPixels = 40
        /// Aantal stilstaande beelden voordat we analyseren (≈130 ms bij 60 fps).
        var settleFrames = 8
        /// Ook zonder waargenomen beweging elke N beelden controleren (vangnet voor supersnelle pijlen).
        var idlePollFrames = 30
        /// Zoveel opeenvolgende positieve persoonsdetecties nodig.
        var personChecksNeeded = 2
        /// Zo lang geen persoon meer gezien (beelden) voordat het bord als leeg telt.
        var clearAfterNoPersonFrames = 45
        /// En zoveel stilstaande beelden.
        var clearStillFrames = 20
        var change = ImageAnalysis.ChangeParameters()
    }

    private enum State: Equatable {
        case needsBaseline(still: Int)
        case idle(sinceCheck: Int)
        case moving
        case settling(Int)
        case atBoard(still: Int)
    }

    let config: Config
    private(set) var mode: Mode = .off
    private(set) var dartsCounted = 0
    private(set) var turnLocked = false
    private var state: State = .needsBaseline(still: 0)
    private var emptyBoard: GrayImage?
    private var reference: GrayImage?
    private var previousMotion: GrayImage?
    private var frame = 0
    private var personStreak = 0
    private var lastPersonFrame = Int.min / 2
    private var forceBaselineRequested = false

    init(config: Config = Config()) { self.config = config }

    var hasBaseline: Bool { emptyBoard != nil }
    var isPlayerAtBoard: Bool { if case .atBoard = state { return true }; return false }

    // MARK: Besturing (vanuit spel/coordinator)

    func setMode(_ m: Mode, awaitingClear: Bool = false) {
        mode = m
        dartsCounted = 0
        turnLocked = awaitingClear
    }

    /// Opnieuw een leeg bord vastleggen (na herkalibratie).
    func resetBaseline() {
        forceBaselineRequested = false
        emptyBoard = nil
        reference = nil
        state = .needsBaseline(still: 0)
    }

    /// Knop "Nu vastleggen": het volgende beeld wordt het lege bord, ook als het niet 100% stil is.
    func forceBaseline() { forceBaselineRequested = true }

    /// Beurt is voorbij (3 pijlen, bust, checkout) → nieuwe pijlen negeren tot het bord leeg is.
    func lockTurn() { turnLocked = true }

    /// Handmatige correctie: zoveel pijlen horen nu bij de beurt.
    func setDartsCounted(_ n: Int) { dartsCounted = n }

    /// "Volgende speler" handmatig ingedrukt. Lag het bord nog vol (beurt vergrendeld),
    /// dan blijft het vergrendeld tot de pijlen eruit zijn — zo krijgt de nieuwe speler geen valse missers.
    func manualNext() { dartsCounted = 0 }

    /// Beurt is heropend na een correctie.
    func resumeTurn(dartsInBoard: Int) {
        dartsCounted = dartsInBoard
        turnLocked = false
    }

    // MARK: Per beeld

    /// - Parameters:
    ///   - motionFrame: klein beeld (bv. 160 px breed) van het bord, elk frame.
    ///   - analysisFrame: groot beeld (bv. 800 px), wordt alleen opgevraagd als het nodig is.
    ///   - personNearBoard: uitkomst van persoonsdetectie als die dit frame gedraaid heeft, anders nil.
    func process(motionFrame: GrayImage, analysisFrame: () -> GrayImage, personNearBoard: Bool?) -> [Event] {
        frame += 1
        let moved: Int
        if let prev = previousMotion {
            moved = ImageAnalysis.changedPixelCount(motionFrame, prev, threshold: config.motionPixelThreshold)
        } else {
            moved = Int.max
        }
        previousMotion = motionFrame
        let isMoving = moved >= config.motionMinPixels

        if let p = personNearBoard {
            personStreak = p ? personStreak + 1 : 0
            if p { lastPersonFrame = frame }
        }

        var events: [Event] = []

        if case .needsBaseline(let still) = state {
            if forceBaselineRequested {
                forceBaselineRequested = false
                let img = analysisFrame()
                emptyBoard = img
                reference = img
                state = .idle(sinceCheck: 0)
                events.append(.baselineCaptured)
                return events
            }
            let calmEnough = moved <= config.baselineMaxMovingPixels
            if calmEnough && personStreak == 0 {
                if still + 1 >= config.clearStillFrames {
                    let img = analysisFrame()
                    emptyBoard = img
                    reference = img
                    state = .idle(sinceCheck: 0)
                    events.append(.baselineCaptured)
                } else {
                    state = .needsBaseline(still: still + 1)
                }
            } else {
                state = .needsBaseline(still: 0)
            }
            return events
        }

        guard mode != .off else { return events }

        // Persoon bij het bord heeft voorrang op alles.
        if personStreak >= config.personChecksNeeded && !isPlayerAtBoard {
            enterAtBoard(&events, reason: .person)
            return events
        }

        switch state {
        case .needsBaseline:
            break
        case .idle(let since):
            if isMoving {
                state = .moving
            } else if since + 1 >= config.idlePollFrames {
                state = .idle(sinceCheck: 0)
                analyzeSettled(analysisFrame(), &events)
            } else {
                state = .idle(sinceCheck: since + 1)
            }
        case .moving:
            if !isMoving { state = .settling(1) }
        case .settling(let n):
            if isMoving {
                state = .moving
            } else if n + 1 >= config.settleFrames {
                state = .idle(sinceCheck: 0)
                analyzeSettled(analysisFrame(), &events)
            } else {
                state = .settling(n + 1)
            }
        case .atBoard(let still):
            let nowStill = isMoving ? 0 : still + 1
            let personGone = frame - lastPersonFrame >= config.clearAfterNoPersonFrames && personStreak == 0
            if personGone && nowStill >= config.clearStillFrames {
                let img = analysisFrame()
                reference = img
                // Licht verandert in de loop van een avond: ververs het lege-bordbeeld als het er nog op lijkt.
                if let empty = emptyBoard, ImageAnalysis.meanAbsDifference(img, empty) < 0.02 { emptyBoard = img }
                dartsCounted = 0
                turnLocked = false
                state = .idle(sinceCheck: 0)
                events.append(.boardCleared)
            } else {
                state = .atBoard(still: nowStill)
            }
        }
        return events
    }

    // MARK: Intern

    private func enterAtBoard(_ events: inout [Event], reason: AtBoardReason) {
        events.append(.playerAtBoard(dartsCounted: dartsCounted, wasLocked: turnLocked, reason: reason))
        lastPersonFrame = frame
        state = .atBoard(still: 0)
    }

    private func analyzeSettled(_ current: GrayImage, _ events: inout [Event]) {
        guard let ref = reference else { reference = current; return }
        let result = ImageAnalysis.analyzeChange(current: current, reference: ref, emptyBoard: emptyBoard, params: config.change)
        switch result.kind {
        case .none:
            reference = current   // kleine lichtverschuivingen opnemen
        case .dartAdded:
            reference = current
            guard !turnLocked, let blob = result.dartBlob else { return }
            dartsCounted += 1
            if mode == .game && dartsCounted >= 3 { turnLocked = true }
            events.append(.dart(tip: ImageAnalysis.locateTip(of: blob, cameraSide: cameraSide)))
        case .dartsRemoved:
            enterAtBoard(&events, reason: .dartsRemoved)
        case .obstruction:
            enterAtBoard(&events, reason: .obstruction)
        }
    }

    /// Wordt door de pipeline gezet bij kalibratie, in analysebeeld-oriëntatie (zelfde als beeld).
    var cameraSide: Vector2D?
}
