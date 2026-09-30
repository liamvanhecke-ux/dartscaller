import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Beslist per camerabeeld wat er gebeurt: pijl geland, speler bij het bord, bord leeg.
/// Bevat GEEN camera- of Vision-code: de pipeline voert beelden en de uitkomst van
/// persoonsdetectie aan. Daardoor volledig te testen met gesimuleerde beelden.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// TRILLINGSFILTER (statief trilt als iemand het scherm aanraakt)
///
///  [TRILLING 1] Touch-lockout   Tijdens een aanraking + `touchLockoutFrames` erna
///                               telt beweging niet mee (geen worp, geen obstructie).
///  [TRILLING 2] Globaal/lokaal  Verschuift het HELE beeld samen (statief), dan wordt
///                               die verschuiving eerst gecompenseerd. Alleen wat daarna
///                               nog verandert (lokaal: een pijl) telt als beweging.
///                               Blijft het statief iets verschoven staan, dan worden
///                               referentie, leeg bord én pijlpunt mee gecorrigeerd.
///  [TRILLING 3] Smoothing       Exponentieel voortschrijdend gemiddelde op de
///                               bewegingsmeting: losse schokjes van 1 frame vallen weg.
/// ─────────────────────────────────────────────────────────────────────────────
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
        /// Nieuwe pijl. Punt in coördinaten van het analysebeeld (zoals bij kalibratie).
        case dart(tip: CGPoint)
        /// Speler (of hand) bij het bord.
        case playerAtBoard(dartsCounted: Int, wasLocked: Bool, reason: AtBoardReason)
        /// Speler weg en beeld stabiel: pijlen zijn opgehaald.
        case boardCleared
        /// Speler weg, maar er zitten nog pijlen in het bord (iemand liep gewoon voorbij).
        case personLeft(dartsCounted: Int)
        /// Kandidaat-worp afgekeurd (ghost). Handig voor debuggen/statistiek.
        case rejected(reason: String)
    }

    struct Config {
        /// Grijsverschil per pixel dat als beweging telt.
        var motionPixelThreshold = 18
        /// Zoveel pixels veranderd tussen twee beelden = beweging.
        var motionMinPixels = 3
        /// Voor het vastleggen van het lege bord: kleine lichtflikkering toelaten.
        var baselineMaxMovingPixels = 40
        /// Aantal stilstaande beelden voordat we analyseren (≈130 ms bij 60 fps).
        var settleFrames = 8
        /// Ook zonder waargenomen beweging elke N beelden controleren. nil = uit.
        var idlePollFrames: Int? = nil
        /// Deel van het bewegingsbeeld dat in één frame beweegt → persoon/hand.
        var obstructionFraction = 0.06
        /// Zoveel frames op rij met grote beweging → persoon/hand (nooit scoren).
        var obstructionFrames = 3
        /// Een worp is kort: langer bewegen (frames, ≈0,8 s bij 60 fps) = persoon.
        var maxMotionFrames = 48
        /// Verificatie van de kandidaat-pijl
        var minElongation = 2.5
        var minContrast = 38.0
        /// Gemiddeld helderheidsverschil van het hele bord → lichtverandering, geen worp.
        var lightingDelta = 6.0
        /// Minimale tijd tussen twee worpen (frames, ≈0,6 s bij 60 fps).
        var cooldownFrames = 36
        /// Zoveel opeenvolgende positieve persoonsdetecties nodig.
        var personChecksNeeded = 2
        /// Zo lang geen persoon meer gezien (beelden) voordat het bord als leeg telt.
        var clearAfterNoPersonFrames = 45
        /// En zoveel stilstaande beelden.
        var clearStillFrames = 20

        // ── [TRILLING 1] Touch-lockout ────────────────────────────────────────
        /// Hoe lang na het loslaten van het scherm beweging genegeerd wordt.
        /// 60 fps: 12 ≈ 200 ms · 21 ≈ 350 ms (standaard) · 30 ≈ 500 ms.
        /// Trilt je statief langer na? Verhoog. Mis je pijlen vlak na een tik? Verlaag.
        var touchLockoutFrames = 21

        // ── [TRILLING 2] Globale beweging (statief) ───────────────────────────
        /// Grootste verschuiving (pixels in het bewegingsbeeld van ±160 px breed) die als
        /// statief-trilling geldt. 3 px ≈ 2% van het beeld. Wankel statief? Verhoog naar 4–5.
        var maxShakeShift = 3
        /// Idem voor het analysebeeld (±800 px breed): blijvende kleine verschuiving compenseren.
        var analysisMaxShift = 12
        /// Een verschuiving wordt pas aangenomen als ze de fout minstens met deze factor verkleint.
        /// Lager (0.6) = strenger, minder vals "trillen"; hoger (0.9) = sneller compenseren.
        var shakeMinImprovement = 0.8

        // ── [TRILLING 3] Smoothing ────────────────────────────────────────────
        /// Gewicht van het nieuwe frame in het voortschrijdend gemiddelde (0…1).
        /// 1.0 = geen smoothing · 0.6 = standaard · 0.3 = sterk (trager, maar rustiger).
        var motionSmoothing = 0.6

        var change = ImageAnalysis.ChangeParameters()
    }

    private enum State: Equatable {
        case needsBaseline(still: Int)
        case idle(sinceCheck: Int)
        case moving(frames: Int, large: Int)
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
    private var lastThrowFrame = Int.min / 2
    /// Laatste reden waarom een kandidaat werd afgekeurd (voor debug-weergave).
    private(set) var lastRejection: String?

    // [TRILLING 1] Aanraking actief / lockout loopt tot dit frame
    private var touchActive = false
    private var lockoutUntilFrame = Int.min / 2
    // [TRILLING 2] Laatst gemeten statief-verschuiving (bewegingsbeeld) en de blijvende
    // verschuiving van het analysebeeld t.o.v. het moment van kalibratie.
    private(set) var lastShakeShift = GlobalMotion.Shift.zero
    private(set) var poseOffset = GlobalMotion.Shift.zero
    // [TRILLING 3] Afgevlakte bewegingsmeting
    private var smoothedMotion = 0.0

    init(config: Config = Config()) { self.config = config }

    var hasBaseline: Bool { emptyBoard != nil }
    var isPlayerAtBoard: Bool { if case .atBoard = state { return true }; return false }
    /// Staat de trillings-lockout nu aan? (voor de statusweergave)
    var isInTouchLockout: Bool { touchActive || frame <= lockoutUntilFrame }

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
        poseOffset = .zero                 // nieuwe kalibratie = nieuwe nulpositie
        state = .needsBaseline(still: 0)
    }

    /// Knop "Nu vastleggen": het volgende beeld wordt het lege bord.
    func forceBaseline() { forceBaselineRequested = true }

    /// Beurt is voorbij (3 pijlen, bust, checkout) → nieuwe pijlen negeren tot het bord leeg is.
    func lockTurn() { turnLocked = true }

    /// Handmatige correctie: zoveel pijlen horen nu bij de beurt.
    func setDartsCounted(_ n: Int) { dartsCounted = n }

    /// "Volgende speler" handmatig ingedrukt.
    func manualNext() { dartsCounted = 0 }

    /// Beurt is heropend na een correctie.
    func resumeTurn(dartsInBoard: Int) {
        dartsCounted = dartsInBoard
        turnLocked = false
    }

    // [TRILLING 1] Aanroepen vanuit de UI (TouchMonitor) bij elke aanraking van het scherm.
    func touchBegan() {
        touchActive = true
        abortPendingMotion()
    }

    func touchEnded() {
        touchActive = false
        lockoutUntilFrame = frame + config.touchLockoutFrames
    }

    // MARK: Per beeld

    /// - Parameters:
    ///   - motionFrame: klein beeld (bv. 160 px breed) van het bord, elk frame.
    ///   - analysisFrame: groot beeld (bv. 800 px), wordt alleen opgevraagd als het nodig is.
    ///   - personNearBoard: uitkomst van persoonsdetectie als die dit frame gedraaid heeft, anders nil.
    func process(motionFrame: GrayImage, analysisFrame: () -> GrayImage, personNearBoard: Bool?) -> [Event] {
        frame += 1

        // [TRILLING 2] Eerst de globale verschuiving (statief) meten en compenseren,
        // dan pas tellen hoeveel er LOKAAL verandert.
        let moved: Int
        if let prev = previousMotion, prev.width == motionFrame.width, prev.height == motionFrame.height {
            let shift = GlobalMotion.estimateShift(from: prev, to: motionFrame, maxShift: config.maxShakeShift,
                                                   minImprovement: config.shakeMinImprovement)
            lastShakeShift = shift
            moved = GlobalMotion.changedPixelCount(prev, motionFrame, shift: shift, threshold: config.motionPixelThreshold)
        } else {
            moved = Int.max
        }
        previousMotion = motionFrame

        // [TRILLING 3] Voortschrijdend gemiddelde: één schokje van 1 frame haalt de drempel niet.
        let a = min(max(config.motionSmoothing, 0.05), 1.0)
        if moved == Int.max {
            smoothedMotion = Double(config.motionMinPixels * 10)
        } else {
            smoothedMotion = a * Double(moved) + (1 - a) * smoothedMotion
            if moved == 0 { smoothedMotion *= 0.5 }          // snel terug naar rust
        }

        // [TRILLING 1] Tijdens aanraking + lockout: beweging telt niet.
        let lockedOut = isInTouchLockout
        // [TRILLING 3] Een NIEUWE beweging starten gebeurt op het afgevlakte signaal (schokjes vallen weg);
        // "is het weer stil?" meten we op het echte frame, zodat de analyse niet later komt.
        let startsMotion = !lockedOut && smoothedMotion >= Double(config.motionMinPixels)
        let isMoving = !lockedOut && moved >= config.motionMinPixels
        let isLargeMotion = !lockedOut && moved != Int.max &&
            smoothedMotion >= config.obstructionFraction * Double(motionFrame.pixels.count)

        if let p = personNearBoard {
            personStreak = p ? personStreak + 1 : 0
            if p { lastPersonFrame = frame }
        }

        var events: [Event] = []

        if case .needsBaseline(let still) = state {
            if forceBaselineRequested && !lockedOut {      // [TRILLING 1] eerst uittrillen
                forceBaselineRequested = false
                let img = analysisFrame()
                emptyBoard = img
                reference = img
                state = .idle(sinceCheck: 0)
                events.append(.baselineCaptured)
                return events
            }
            let calmEnough = !lockedOut && moved <= config.baselineMaxMovingPixels
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

        // [TRILLING 1] Een begonnen beweging die in de lockout valt, was de trilling zelf.
        if lockedOut {
            abortPendingMotion()
            return events
        }

        switch state {
        case .needsBaseline:
            break
        case .idle(let since):
            if isLargeMotion {
                enterAtBoard(&events, reason: .obstruction)
            } else if startsMotion && isMoving {
                state = .moving(frames: 1, large: 0)
            } else if let poll = config.idlePollFrames, since + 1 >= poll {
                state = .idle(sinceCheck: 0)
                analyzeSettled(analysisFrame(), &events)
            } else {
                state = .idle(sinceCheck: since + 1)
            }
        case .moving(let frames, let large):
            let nowLarge = isLargeMotion ? large + 1 : 0
            if nowLarge >= config.obstructionFrames {
                enterAtBoard(&events, reason: .obstruction)          // persoon/hand: nooit scoren
            } else if frames + 1 > config.maxMotionFrames {
                enterAtBoard(&events, reason: .obstruction)          // te lang bewogen voor een worp
            } else if !isMoving {
                state = .settling(1)
            } else {
                state = .moving(frames: frames + 1, large: nowLarge)
            }
        case .settling(let n):
            if isLargeMotion {
                enterAtBoard(&events, reason: .obstruction)
            } else if isMoving {
                state = .moving(frames: 1, large: 0)                 // pijl trilt nog na
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
                alignToCurrent(img)                                   // [TRILLING 2]
                reference = img
                state = .idle(sinceCheck: 0)
                // Zitten er nog pijlen in? Vergelijk met het lege bord.
                var stillDarts = false
                if let empty = emptyBoard {
                    let rest = ImageAnalysis.analyzeChange(current: img, reference: empty, emptyBoard: nil, params: config.change)
                    stillDarts = rest.kind == .dartAdded
                    if rest.kind == .none { emptyBoard = img }        // licht bijwerken
                }
                if stillDarts {
                    events.append(.personLeft(dartsCounted: dartsCounted))
                } else {
                    dartsCounted = 0
                    turnLocked = false
                    events.append(.boardCleared)
                }
            } else {
                state = .atBoard(still: nowStill)
            }
        }
        return events
    }

    // MARK: Intern

    /// [TRILLING 1] Beweging die tijdens een aanraking begon, verwerpen (niet analyseren).
    private func abortPendingMotion() {
        switch state {
        case .moving, .settling: state = .idle(sinceCheck: 0)
        default: break
        }
    }

    /// [TRILLING 2] Is het statief blijvend een paar pixels verschoven? Dan referentie en leeg bord
    /// mee verschuiven, en bijhouden hoeveel (voor de pijlpunt → kalibratie).
    /// - Returns: de toegepaste verschuiving.
    @discardableResult
    private func alignToCurrent(_ current: GrayImage) -> GlobalMotion.Shift {
        guard let ref = reference else { return .zero }
        let shift = GlobalMotion.estimateShift(from: ref, to: current, maxShift: config.analysisMaxShift,
                                               minImprovement: config.shakeMinImprovement)
        guard !shift.isZero else { return .zero }
        reference = GlobalMotion.shifted(ref, by: shift)
        if let empty = emptyBoard { emptyBoard = GlobalMotion.shifted(empty, by: shift) }
        poseOffset = poseOffset + shift
        return shift
    }

    private func enterAtBoard(_ events: inout [Event], reason: AtBoardReason) {
        events.append(.playerAtBoard(dartsCounted: dartsCounted, wasLocked: turnLocked, reason: reason))
        lastPersonFrame = frame
        state = .atBoard(still: 0)
    }

    private func analyzeSettled(_ current: GrayImage, _ events: inout [Event]) {
        guard reference != nil else { reference = current; return }
        alignToCurrent(current)                                        // [TRILLING 2]
        let ref = reference!
        let result = ImageAnalysis.analyzeChange(current: current, reference: ref, emptyBoard: emptyBoard, params: config.change)
        switch result.kind {
        case .none:
            reference = current   // kleine lichtverschuivingen opnemen
        case .dartAdded:
            reference = current
            guard !turnLocked, let blob = result.dartBlob else { return }
            // Meervoudige verificatie: alles moet kloppen, anders is het een ghost.
            var reasons: [String] = []
            let elong = ImageAnalysis.elongation(of: blob)
            if elong < config.minElongation { reasons.append("niet langwerpig (\(String(format: "%.1f", elong)))") }
            let contrast = ImageAnalysis.contrast(of: blob, current, ref)
            if contrast < config.minContrast { reasons.append("zacht contrast (schaduw?)") }
            let light = abs(ImageAnalysis.meanBrightness(current) - ImageAnalysis.meanBrightness(ref))
            if light > config.lightingDelta { reasons.append("lichtverandering") }
            if frame - lastThrowFrame < config.cooldownFrames { reasons.append("binnen cooldown") }
            if !reasons.isEmpty {
                lastRejection = reasons.joined(separator: ", ")
                events.append(.rejected(reason: lastRejection!))
                return
            }
            lastThrowFrame = frame
            dartsCounted += 1
            if mode == .game && dartsCounted >= 3 { turnLocked = true }
            let tip = ImageAnalysis.locateTip(of: blob, cameraSide: cameraSide)
            // [TRILLING 2] Punt terugrekenen naar de positie van het beeld bij kalibratie.
            let corrected = CGPoint(x: Double(tip.x) - Double(poseOffset.dx), y: Double(tip.y) - Double(poseOffset.dy))
            events.append(.dart(tip: corrected))
        case .dartsRemoved:
            enterAtBoard(&events, reason: .dartsRemoved)
        case .obstruction:
            enterAtBoard(&events, reason: .obstruction)
        }
    }

    /// Wordt door de pipeline gezet bij kalibratie, in analysebeeld-oriëntatie (zelfde als beeld).
    var cameraSide: Vector2D?
}
