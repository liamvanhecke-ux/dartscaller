import Foundation
import CoreGraphics
import Observation

/// Eén camera voor de hele app. Blijft gekalibreerd tussen wedstrijden zolang de camera niet verplaatst wordt.
@Observable
@MainActor
final class CameraSystem {

    enum Step: Equatable {
        case idle
        case denied
        case failed(String)
        case searching          // bord zoeken
        case zooming            // automatisch inzoomen
        case focusing           // scherpstellen + belichting vergrendelen
        case searchFailed
        case calibrating        // gebruiker controleert de 4 punten
        case waitingForBaseline // leeg bord vastleggen
        case ready
    }

    private(set) var step: Step = .idle
    let controller = CameraController()
    let pipeline = DartVisionPipeline()

    private(set) var snapshot: CGImage? = nil
    private(set) var imageSize: CGSize = .zero
    /// De 4 kalibratiepunten in beeldpixels (linksboven). Bewerkbaar in het kalibratiescherm.
    var calibrationPoints: [CGPoint] = []
    private(set) var calibration: BoardCalibration? = nil
    /// De 4 punten zijn door het YOLO-model gevonden (gebruiker bevestigt enkel).
    private(set) var pointsFoundByModel = false
    var hasModel: Bool { modelSource != nil }
    /// Welk model de pipeline gebruikt (observeerbaar voor de UI).
    private(set) var modelSource: DartDetector.Source? = nil

    /// Na importeren/verwijderen van een eigen model.
    func reloadModel() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pipeline.reloadModel { [weak self] source in
                self?.modelSource = source
                cont.resume()
            }
        }
    }

    /// De lopende wedstrijd luistert hier naar worp-events.
    @ObservationIgnored var eventHandler: ((VisionEvent) -> Void)? = nil

    @ObservationIgnored private var didAutoZoom = false
    @ObservationIgnored private var searchTimeout: Task<Void, Never>? = nil

    init() {
        modelSource = pipeline.modelSource
        pipeline.onEvent = { [weak self] event in self?.handle(event) }
    }

    var isReady: Bool { step == .ready }

    /// Kalibratie op basis van de huidige (nog niet bevestigde) punten — voor de live overlay.
    var previewCalibration: BoardCalibration? {
        guard calibrationPoints.count == 4, imageSize != .zero else { return nil }
        return BoardCalibration(imagePoints: calibrationPoints, imageSize: imageSize)
    }

    // MARK: - Setup

    func beginSetup() async {
        guard await CameraController.requestAccess() else {
            step = .denied
            return
        }
        do {
            try controller.configure(delegate: pipeline, queue: pipeline.queue)
        } catch {
            step = .failed(error.localizedDescription)
            return
        }
        calibration = nil
        calibrationPoints = []
        didAutoZoom = false
        pipeline.stopTracking()
        controller.setLocked(false)
        controller.setZoom(1, animated: false)
        controller.start()
        startSearching()
    }

    func retrySearch() {
        didAutoZoom = false
        controller.setLocked(false)
        controller.setZoom(1, animated: true)
        startSearching()
    }

    /// Geen automatische detectie: zelf de punten plaatsen.
    func calibrateManually() {
        searchTimeout?.cancel()
        pipeline.stopBoardSearch()
        capture(boardBox: nil)
    }

    /// Bestaande kalibratie opnieuw controleren (bv. camera een beetje verschoven).
    func recalibrate() {
        controller.start()
        pipeline.stopTracking()
        controller.setLocked(false)
        capture(boardBox: nil)
    }

    /// Nieuwe wedstrijd met de bestaande kalibratie.
    func resume() {
        controller.start()
        pipeline.setMode(.off)
    }

    func pause() {
        pipeline.setMode(.off)
        controller.stop()
    }

    /// Bevestig de 4 punten. Geeft false als ze geen geldig bord vormen.
    @discardableResult
    func confirmCalibration() -> Bool {
        guard let cal = previewCalibration else { return false }
        calibration = cal
        step = .waitingForBaseline
        pipeline.applyCalibration(cal)
        return true
    }

    /// Knop in de setup: lege bord nu vastleggen (als het automatisch niet lukt).
    func captureBaselineNow() {
        guard step == .waitingForBaseline else { return }
        pipeline.forceBaseline()
    }

    // MARK: - Intern

    private func startSearching() {
        step = .searching
        pipeline.startBoardSearch()
        searchTimeout?.cancel()
        searchTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.step == .searching else { return }
            self.pipeline.stopBoardSearch()
            self.step = .searchFailed
        }
    }

    private func handle(_ event: VisionEvent) {
        switch event {
        case .boardFound(let box, let size):
            boardFound(box, imageSize: size)
        case .baselineCaptured:
            if step == .waitingForBaseline { step = .ready }
            eventHandler?(event)
        default:
            eventHandler?(event)
        }
    }

    private func boardFound(_ box: CGRect, imageSize size: CGSize) {
        guard step == .searching else { return }
        searchTimeout?.cancel()
        let k = CameraMath.zoomFactor(forBoardBox: box, imageSize: size)
        if !didAutoZoom && k > 1.1 {
            // Inzoomen tot het bord het beeld vult, daarna opnieuw zoeken voor de exacte positie.
            didAutoZoom = true
            step = .zooming
            controller.setZoom(controller.zoomFactor * k, animated: true)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.step == .zooming else { return }
                self.startSearching()
            }
        } else {
            capture(boardBox: box)
        }
    }

    private func capture(boardBox: CGRect?) {
        step = .focusing
        controller.setLocked(false)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))      // autofocus/belichting laten stabiliseren
            guard let self, self.step == .focusing else { return }
            self.controller.setLocked(true)
            try? await Task.sleep(for: .milliseconds(300))
            self.pipeline.requestSnapshot { [weak self] image, size in
                guard let self, self.step == .focusing else { return }
                self.snapshot = image
                if let box = boardBox {
                    self.calibrationPoints = ImageAnalysis.initialCalibrationGuess(boardBox: box)
                } else if self.calibrationPoints.count != 4 || self.imageSize != size {
                    self.calibrationPoints = CameraMath.defaultCalibrationGuess(imageSize: size)
                }
                self.imageSize = size
                self.pointsFoundByModel = false
                guard self.pipeline.hasModel else {
                    self.step = .calibrating
                    return
                }
                // YOLO zoekt de 4 kalibratiepunten; lukt dat niet, dan blijft de schatting staan.
                self.pipeline.detectCalibration(in: image) { [weak self] points in
                    guard let self, self.step == .focusing else { return }
                    if let points, BoardCalibration(imagePoints: points, imageSize: size) != nil {
                        self.calibrationPoints = points
                        self.pointsFoundByModel = true
                    }
                    self.step = .calibrating
                }
            }
        }
    }
}
