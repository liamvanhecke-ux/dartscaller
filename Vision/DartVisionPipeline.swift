import AVFoundation
import CoreImage
import Vision

enum VisionEvent {
    /// Setup: dartbord gevonden (bounding box van de double-ring, beeldpixels linksboven).
    case boardFound(CGRect, imageSize: CGSize)
    case baselineCaptured
    /// `byModel`: positie bepaald door het YOLO-model (anders frame-difference-heuristiek).
    /// `capture`: bord-uitsnede van dat moment (voor trainingsdata).
    case dart(DartHit, imagePoint: CGPoint, byModel: Bool, capture: FrameCapture?)
    case playerAtBoard(dartsCounted: Int, wasLocked: Bool, reason: ThrowTracker.AtBoardReason)
    case boardCleared
    /// Persoon weg, maar er zitten nog pijlen in (iemand liep voorbij).
    case personLeft(dartsCounted: Int)
    /// Kandidaat-worp afgekeurd (schaduw, licht, cooldown…).
    case ignored(reason: String)
}

/// Verwerkt camerabeelden op een eigen queue. Alle status leeft op `queue`;
/// events gaan in volgorde naar de main thread via `onEvent`.
final class DartVisionPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private enum Stage { case idle, searchingBoard, tracking }

    let queue = DispatchQueue(label: "darts.vision", qos: .userInteractive)
    /// Wordt op de main thread aangeroepen. Zet dit vóór de camera start (vanaf de main thread).
    var onEvent: (@MainActor (VisionEvent) -> Void)?

    // Beeldresoluties voor de analyse (in pixels breed)
    private let motionWidth = 160
    private let analysisWidth = 800
    private let boardSearchWidth = 240
    private let modelInputWidth = 800          // DartsYOLO is getraind en geëxporteerd op 800×800
    private let personCheckEvery = 6          // ≈ 10× per seconde bij 60 fps

    // Alleen aanraken op `queue`:
    private let renderer = FrameRenderer()
    private let tracker = ThrowTracker()
    /// nil als er geen DartsYOLO-model in de app zit. Alleen aanraken op `queue`.
    private var detector = DartDetector()
    private let modelInfoLock = NSLock()
    private var _modelSource: DartDetector.Source?
    /// Punten (mm) van de pijlen die deze beurt al in het bord zitten — zodat YOLO de NIEUWE pijl kiest.
    private var dartsInBoardMM: [CGPoint] = []
    private var stage: Stage = .idle
    private var calibration: BoardCalibration?
    private var frameIndex = 0
    private var snapshotRequest: (@MainActor (CGImage, CGSize) -> Void)?
    private var lastBoardBox: CGRect?
    private var stableBoardHits = 0
    private let personRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        return r
    }()

    override init() {
        super.init()
        _modelSource = detector?.source
    }

    /// Welk YOLO-model is geladen (nil = geen). Veilig vanaf elke thread.
    var modelSource: DartDetector.Source? {
        modelInfoLock.lock(); defer { modelInfoLock.unlock() }
        return _modelSource
    }
    var hasModel: Bool { modelSource != nil }

    /// Model opnieuw laden (na importeren van een hertraind model). Completion op main.
    func reloadModel(completion: @escaping @MainActor (DartDetector.Source?) -> Void) {
        queue.async {
            self.detector = DartDetector()
            let source = self.detector?.source
            self.modelInfoLock.lock(); self._modelSource = source; self.modelInfoLock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(source) } }
        }
    }

    // MARK: - Besturing (thread-safe)

    func startBoardSearch() {
        queue.async {
            self.stage = .searchingBoard
            self.lastBoardBox = nil
            self.stableBoardHits = 0
        }
    }

    func stopBoardSearch() {
        queue.async { if self.stage == .searchingBoard { self.stage = .idle } }
    }

    func stopTracking() {
        queue.async {
            self.stage = .idle
            self.tracker.setMode(.off)
        }
    }

    /// Volgend beeld als CGImage (voor het kalibratiescherm). Completion op main.
    func requestSnapshot(_ completion: @escaping @MainActor (CGImage, CGSize) -> Void) {
        queue.async { self.snapshotRequest = completion }
    }

    /// Kalibratie toepassen en een nieuw leeg-bordbeeld vastleggen.
    func applyCalibration(_ cal: BoardCalibration) {
        queue.async {
            self.calibration = cal
            self.tracker.cameraSide = cal.cameraSideDirection
            self.tracker.setMode(.off)
            self.tracker.resetBaseline()
            self.stage = .tracking
        }
    }

    func setMode(_ mode: ThrowTracker.Mode, awaitingClear: Bool = false) {
        queue.async {
            self.tracker.setMode(mode, awaitingClear: awaitingClear)
            if !awaitingClear { self.dartsInBoardMM = [] }
        }
    }

    /// Kalibratiepunten laten zoeken door het YOLO-model op een volledig beeld. Completion op main.
    func detectCalibration(in image: CGImage, completion: @escaping @MainActor ([CGPoint]?) -> Void) {
        queue.async {
            var points: [CGPoint]?
            if let detector = self.detector {
                points = YoloInterpreter.calibrationPoints(detector.detect(in: image), labels: detector.labels)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(points) } }
        }
    }

    /// Start van de wedstrijd. Zitten er nog (bull-off) pijlen in het bord, dan eerst wachten tot ze eruit zijn.
    func startGameMode() {
        queue.async {
            let boardHasDarts = self.tracker.dartsCounted > 0 || self.tracker.turnLocked || self.tracker.isPlayerAtBoard
            self.tracker.setMode(.game, awaitingClear: boardHasDarts)
        }
    }

    func lockTurn() { queue.async { self.tracker.lockTurn() } }
    func forceBaseline() { queue.async { self.tracker.forceBaseline() } }

    // [TRILLING 1] Aanraking van het scherm (statief kan trillen). Veilig vanaf elke thread.
    func touchBegan() { queue.async { self.tracker.touchBegan() } }
    func touchEnded() { queue.async { self.tracker.touchEnded() } }
    func resumeTurn(dartsInBoard n: Int) { queue.async { self.tracker.resumeTurn(dartsInBoard: n) } }
    func setDartsCounted(_ n: Int) { queue.async { self.tracker.setDartsCounted(n) } }
    func manualNext() { queue.async { self.tracker.manualNext() } }

    // MARK: - Beelden

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex += 1
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        if let request = snapshotRequest, let cg = renderer.cgImage(image) {
            snapshotRequest = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { request(cg, size) } }
        }

        switch stage {
        case .idle:
            return
        case .searchingBoard:
            searchBoard(image, size: size)
        case .tracking:
            track(image, pixelBuffer: pixelBuffer, size: size)
        }
    }

    // MARK: Bord zoeken (auto-zoom)

    private func searchBoard(_ image: CIImage, size: CGSize) {
        guard frameIndex % 8 == 0 else { return }
        let small = renderer.rgba(image, rect: CGRect(origin: .zero, size: size), targetWidth: boardSearchWidth)
        guard let found = ImageAnalysis.detectBoard(in: small) else {
            stableBoardHits = 0
            lastBoardBox = nil
            return
        }
        let f = size.width / CGFloat(small.width)
        let box = CGRect(x: found.minX * f, y: found.minY * f, width: found.width * f, height: found.height * f)

        // Pas melden als het bord 3× na elkaar op dezelfde plek staat (camera stil).
        if let last = lastBoardBox,
           abs(last.midX - box.midX) < size.width * 0.03,
           abs(last.midY - box.midY) < size.width * 0.03,
           abs(last.width - box.width) < last.width * 0.08 {
            stableBoardHits += 1
        } else {
            stableBoardHits = 1
        }
        lastBoardBox = box
        if stableBoardHits >= 3 {
            stage = .idle
            emit(.boardFound(box, imageSize: size))
        }
    }

    // MARK: Worpen volgen

    private func track(_ image: CIImage, pixelBuffer: CVPixelBuffer, size: CGSize) {
        guard let cal = calibration else { return }
        // Andere beeldgrootte dan bij kalibratie (bv. camera herstart met ander formaat) → niet meten.
        guard abs(size.width - cal.imageSize.width) < 1, abs(size.height - cal.imageSize.height) < 1 else { return }

        var person: Bool?
        if frameIndex % personCheckEvery == 0 {
            person = personNearBoard(pixelBuffer, roi: cal.roi, size: size)
        }

        let roi = cal.roi
        let motion = renderer.gray(image, rect: roi, targetWidth: motionWidth)
        let events = tracker.process(
            motionFrame: motion,
            analysisFrame: { self.renderer.gray(image, rect: roi, targetWidth: self.analysisWidth) },
            personNearBoard: person)

        for e in events {
            switch e {
            case .baselineCaptured:
                emit(.baselineCaptured)
            case .dart(let tip):
                // 1. Frame-difference: waar veranderde het beeld (= welke pijl is nieuw)?
                let (w, h) = FrameRenderer.outputSize(for: roi, targetWidth: analysisWidth)
                let diffPoint = CGPoint(x: roi.minX + tip.x * roi.width / CGFloat(w),
                                        y: roi.minY + tip.y * roi.height / CGFloat(h))
                var mm = cal.toBoard.apply(diffPoint)
                var byModel = false
                // 2. YOLO: exacte positie van de punt van díe pijl.
                let crop = renderer.cgImage(image, rect: roi, targetWidth: modelInputWidth)
                if let crop, let modelMM = modelDartPoint(crop, cal: cal, hintMM: mm) {
                    mm = modelMM
                    byModel = true
                }
                dartsInBoardMM.append(mm)
                let capture = crop.map { FrameCapture(image: $0, roi: roi, boardToImage: cal.toImage) }
                emit(.dart(BoardGeometry.hit(at: mm), imagePoint: cal.toImage.apply(mm), byModel: byModel, capture: capture))
            case .playerAtBoard(let n, let locked, let reason):
                emit(.playerAtBoard(dartsCounted: n, wasLocked: locked, reason: reason))
            case .boardCleared:
                dartsInBoardMM = []
                emit(.boardCleared)
            case .personLeft(let n):
                emit(.personLeft(dartsCounted: n))
            case .rejected(let reason):
                emit(.ignored(reason: reason))
            }
        }
    }

    /// Draait het YOLO-model op de bord-uitsnede en kiest de punt van de nieuwe pijl.
    private func modelDartPoint(_ crop: CGImage, cal: BoardCalibration, hintMM: CGPoint) -> CGPoint? {
        guard let detector else { return nil }
        let sx = cal.roi.width / CGFloat(crop.width), sy = cal.roi.height / CGFloat(crop.height)
        // [TRILLING 2] Blijvende statief-verschuiving (analysepixels) → beeldpixels, en terugrekenen
        // naar de positie bij kalibratie.
        let (aw, _) = FrameRenderer.outputSize(for: cal.roi, targetWidth: analysisWidth)
        let k = cal.roi.width / CGFloat(aw)
        let offX = CGFloat(tracker.poseOffset.dx) * k, offY = CGFloat(tracker.poseOffset.dy) * k
        let detections = detector.detect(in: crop).map {
            Detection(label: $0.label,
                      point: CGPoint(x: cal.roi.minX + $0.point.x * sx - offX,
                                     y: cal.roi.minY + $0.point.y * sy - offY),
                      confidence: $0.confidence)
        }
        let tips = YoloInterpreter.dartTips(detections, labels: detector.labels)
        return YoloInterpreter.newDartPoint(candidates: tips, known: dartsInBoardMM, hint: hintMM, toBoard: cal.toBoard)
    }

    /// Staat er een persoon in beeld die het bord (deels) afdekt?
    private func personNearBoard(_ pixelBuffer: CVPixelBuffer, roi: CGRect, size: CGSize) -> Bool {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([personRequest]) } catch { return false }
        for obs in personRequest.results ?? [] where obs.confidence > 0.5 {
            let b = obs.boundingBox   // genormaliseerd, oorsprong linksonder
            let rect = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                              width: b.width * size.width, height: b.height * size.height)
            if rect.intersects(roi) { return true }
        }
        return false
    }

    private func emit(_ e: VisionEvent) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onEvent?(e) } }
    }
}
