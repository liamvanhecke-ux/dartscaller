import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import Observation

/// Bord-uitsnede op het moment dat een pijl gedetecteerd werd (voor trainingsdata).
struct FrameCapture {
    let image: CGImage
    /// Uitsnede in het volledige camerabeeld (pixels, linksboven).
    let roi: CGRect
    /// mm → volledig camerabeeld
    let boardToImage: Homography
}

/// Zelflerend systeem:
/// 1. Direct: `CorrectionLearner` schuift detecties bij op basis van correcties én gewone worpen.
/// 2. Later: elke worp wordt een gelabelde trainingsfoto → exporteren → model hertrainen → importeren.
@Observable
@MainActor
final class LearningCenter {

    var learnFromCorrections: Bool {
        didSet { UserDefaults.standard.set(learnFromCorrections, forKey: "learning.enabled") }
    }
    var collectTrainingData: Bool {
        didSet { UserDefaults.standard.set(collectTrainingData, forKey: "learning.collect") }
    }

    private(set) var learner: CorrectionLearner
    private(set) var sampleCount = 0
    private(set) var isExporting = false
    /// AI-trainingsmodus: door de speler bevestigde / gecorrigeerde beurten.
    private(set) var positiveCount = 0
    private(set) var needsRetrainingCount = 0

    static let maxSamples = 1500

    private struct Tracked {
        let raw: CGPoint
        let shown: CGPoint
    }
    /// Oorspronkelijke pijl-id → ruwe en getoonde positie (enkel camerapijlen van deze app-sessie).
    @ObservationIgnored private var tracked: [UUID: Tracked] = [:]
    /// Id van een (gecorrigeerde) DartHit → id van de oorspronkelijke camerapijl.
    @ObservationIgnored private var origin: [UUID: UUID] = [:]
    /// Eindlabels per fysieke pijl (bewaard op schijf).
    @ObservationIgnored private var labels: [UUID: DartLabel] = [:]
    @ObservationIgnored private let io = DispatchQueue(label: "darts.learning.io", qos: .utility)

    init() {
        let d = UserDefaults.standard
        learnFromCorrections = d.object(forKey: "learning.enabled") as? Bool ?? true
        collectTrainingData = d.object(forKey: "learning.collect") as? Bool ?? true
        learner = Self.load(CorrectionLearner.self, from: Self.learnerURL) ?? CorrectionLearner()
        labels = Self.load([UUID: DartLabel].self, from: Self.labelsURL) ?? [:]
        sampleCount = (try? FileManager.default.contentsOfDirectory(atPath: Self.samplesURL.path)
            .filter { $0.hasSuffix(".json") }.count) ?? 0
        positiveCount = Self.countImages(in: Self.trainingModeURL(verified: true))
        needsRetrainingCount = Self.countImages(in: Self.trainingModeURL(verified: false))
    }

    // MARK: - Tijdens het spel

    /// Nieuwe camerapijl: pas de geleerde correctie toe en bewaar eventueel het beeld.
    /// - Parameter dartsInBoard: pijlen die al in het bord zitten (deze beurt).
    func adjust(_ hit: DartHit, capture: FrameCapture?, dartsInBoard: [DartHit]) -> DartHit {
        guard let raw = hit.boardPoint else { return hit }
        let shown = learnFromCorrections ? learner.apply(raw) : raw
        let result = BoardGeometry.hit(at: shown)
        tracked[result.id] = Tracked(raw: raw, shown: shown)
        origin[result.id] = result.id

        if collectTrainingData, let capture, sampleCount < Self.maxSamples {
            let ids = dartsInBoard.filter { !$0.isMiss }.map { originID(of: $0.id) } + [result.id]
            saveSample(capture, dartIDs: ids)
        }
        return result
    }

    /// Speler heeft een pijl aangepast. Geeft true als er iets geleerd is.
    @discardableResult
    func corrected(old: DartHit, new: DartHit) -> Bool {
        let o = originID(of: old.id)
        origin[new.id] = o
        guard let t = tracked[o] else { return false }
        if old.sameValue(as: new) {
            confirm([new])
            return false
        }
        if new.isMiss {
            // Mis: echte pijl in de rand óf valse detectie — onzeker, dus niet leren en niet labelen.
            labels[o] = nil
            persistLabels()
            return false
        }
        let target: CGPoint
        if learnFromCorrections {
            target = learner.observeCorrected(raw: t.raw, shown: t.shown, correct: new)
            persistLearner()
        } else {
            target = CorrectionLearner.nearestPoint(in: new, to: t.shown)
        }
        labels[o] = .point(x: Double(target.x), y: Double(target.y), approximate: true)
        persistLabels()
        return true
    }

    /// Pijl ongedaan gemaakt: onzeker wat er echt in het bord zat → beelden met deze pijl niet gebruiken.
    func removed(_ hit: DartHit) {
        let o = originID(of: hit.id)
        tracked[o] = nil
        labels[o] = nil
        persistLabels()
    }

    /// Beurt afgesloten zonder (verdere) correctie: de getoonde posities kloppen.
    func confirm(_ darts: [DartHit]) {
        var changed = false
        for d in darts {
            let o = originID(of: d.id)
            guard let t = tracked[o], labels[o] == nil else { continue }
            if learnFromCorrections { learner.observeConfirmed(raw: t.raw, shown: t.shown) }
            labels[o] = .point(x: Double(t.shown.x), y: Double(t.shown.y), approximate: false)
            changed = true
        }
        if changed {
            persistLabels()
            if learnFromCorrections { persistLearner() }
        }
    }

    // MARK: - AI-trainingsmodus

    /// Eén beurt uit de trainingsmodus opslaan.
    /// - verified: true = "Klopt helemaal" → Positives/, false = gecorrigeerd → Needs_Retraining/
    /// - dartsMM: posities (mm) van ALLE pijlen in het bord op deze foto (missers niet).
    func saveTrainingTurn(capture: FrameCapture, dartsMM: [CGPoint], verified: Bool) {
        let roi = [Double(capture.roi.minX), Double(capture.roi.minY), Double(capture.roi.width), Double(capture.roi.height)]
        let lines = TrainingLabelMaker.yoloLines(roi: roi, boardToImage: capture.boardToImage.m, dartsMM: dartsMM)
        let dir = Self.trainingModeURL(verified: verified)
        let name = "\(Self.stamp())_\(UUID().uuidString.prefix(6))"
        let image = capture.image
        if verified { positiveCount += 1 } else { needsRetrainingCount += 1 }
        io.async {
            let fm = FileManager.default
            let images = dir.appendingPathComponent("images"), labels = dir.appendingPathComponent("labels")
            try? fm.createDirectory(at: images, withIntermediateDirectories: true)
            try? fm.createDirectory(at: labels, withIntermediateDirectories: true)
            let jpg = images.appendingPathComponent("\(name).jpg")
            guard let dest = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            try? (lines.joined(separator: "\n") + "\n").write(to: labels.appendingPathComponent("\(name).txt"),
                                                            atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func trainingModeURL(verified: Bool) -> URL {
        baseURL.appendingPathComponent("TrainingMode/\(verified ? "Positives" : "Needs_Retraining")", isDirectory: true)
    }

    nonisolated private static func countImages(in dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path)
            .filter { $0.hasSuffix(".jpg") }.count) ?? 0
    }

    nonisolated private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    func resetLearning() {
        learner.reset()
        persistLearner()
    }

    func deleteTrainingData() {
        labels = [:]
        sampleCount = 0
        positiveCount = 0
        needsRetrainingCount = 0
        let url = Self.samplesURL, labelsURL = Self.labelsURL
        let tm = Self.baseURL.appendingPathComponent("TrainingMode")
        io.async {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: labelsURL)
            try? FileManager.default.removeItem(at: tm)
        }
    }

    private func originID(of id: UUID) -> UUID { origin[id] ?? id }

    // MARK: - Export (YOLO-dataset als zip)

    /// Bouwt een zip met images/, labels/ en data.yaml. Enkel volledig gelabelde beelden.
    func exportDataset() async -> (url: URL, count: Int)? {
        isExporting = true
        defer { isExporting = false }
        let labelsCopy = labels
        let samplesURL = Self.samplesURL
        return await withCheckedContinuation { continuation in
            io.async {
                continuation.resume(returning: Self.buildExport(samplesURL: samplesURL, labels: labelsCopy))
            }
        }
    }

    nonisolated private static func buildExport(samplesURL: URL, labels: [UUID: DartLabel]) -> (url: URL, count: Int)? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("DartsCaller-dataset")
        try? fm.removeItem(at: folder)
        let images = folder.appendingPathComponent("images/train")
        let labelDir = folder.appendingPathComponent("labels/train")
        do {
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            try fm.createDirectory(at: labelDir, withIntermediateDirectories: true)
        } catch { return nil }

        var count = 0
        let files = (try? fm.contentsOfDirectory(at: samplesURL, includingPropertiesForKeys: nil)) ?? []
        for json in files where json.pathExtension == "json" {
            guard let data = try? Data(contentsOf: json),
                  let sample = try? JSONDecoder().decode(TrainingSample.self, from: data),
                  let lines = TrainingLabelMaker.yoloLines(for: sample, labels: labels) else { continue }
            let jpg = samplesURL.appendingPathComponent(sample.imageFileName)
            guard fm.fileExists(atPath: jpg.path) else { continue }
            try? fm.copyItem(at: jpg, to: images.appendingPathComponent(sample.imageFileName))
            try? lines.joined(separator: "\n").write(to: labelDir.appendingPathComponent("\(sample.id.uuidString).txt"),
                                                     atomically: true, encoding: .utf8)
            count += 1
        }
        // AI-trainingsmodus: Positives/ en Needs_Retraining/ als aparte mappen (zelfde YOLO-structuur)
        var dirs = count > 0 ? ["images/train"] : []
        for (verified, sub) in [(true, "positives"), (false, "needs_retraining")] {
            let src = trainingModeURL(verified: verified)
            guard let files = try? fm.contentsOfDirectory(atPath: src.appendingPathComponent("images").path),
                  !files.isEmpty else { continue }
            let dst = folder.appendingPathComponent(sub)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try? fm.copyItem(at: src.appendingPathComponent("images"), to: dst.appendingPathComponent("images"))
            try? fm.copyItem(at: src.appendingPathComponent("labels"), to: dst.appendingPathComponent("labels"))
            count += files.filter { $0.hasSuffix(".jpg") }.count
            dirs.append("\(sub)/images")
        }
        try? TrainingLabelMaker.datasetYAML(imageDirs: dirs)
            .write(to: folder.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        guard count > 0 else { return nil }

        // Zip maken met de ingebouwde Files-functie (geen externe library nodig).
        var zipURL: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &error) { tempZip in
            let dest = fm.temporaryDirectory.appendingPathComponent("DartsCaller-dataset.zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: tempZip, to: dest)) != nil { zipURL = dest }
        }
        return zipURL.map { ($0, count) }
    }

    // MARK: - Nieuw model importeren (zonder Xcode)

    /// Compileert een .mlpackage/.mlmodel op het toestel en zet het klaar als eigen model.
    nonisolated static func installModel(from url: URL) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let compiled = try await MLModel.compileModel(at: url)
        let fm = FileManager.default
        let dest = DartDetector.customModelURL
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: compiled, to: dest)
        try? fm.removeItem(at: compiled)
    }

    nonisolated static func removeCustomModel() {
        try? FileManager.default.removeItem(at: DartDetector.customModelURL)
    }

    // MARK: - Opslag

    nonisolated static var baseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Learning", isDirectory: true)
    }
    nonisolated static var samplesURL: URL { baseURL.appendingPathComponent("Samples", isDirectory: true) }
    nonisolated static var learnerURL: URL { baseURL.appendingPathComponent("learner.json") }
    nonisolated static var labelsURL: URL { baseURL.appendingPathComponent("labels.json") }

    private func saveSample(_ capture: FrameCapture, dartIDs: [UUID]) {
        let sample = TrainingSample(width: capture.image.width, height: capture.image.height,
                                    roi: [Double(capture.roi.minX), Double(capture.roi.minY),
                                          Double(capture.roi.width), Double(capture.roi.height)],
                                    boardToImage: capture.boardToImage.m, dartIDs: dartIDs)
        sampleCount += 1
        let dir = Self.samplesURL
        let image = capture.image
        io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let jpg = dir.appendingPathComponent(sample.imageFileName)
            guard let dest = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest), let data = try? JSONEncoder().encode(sample) else { return }
            try? data.write(to: dir.appendingPathComponent("\(sample.id.uuidString).json"), options: .atomic)
        }
    }

    private func persistLearner() { persist(learner, to: Self.learnerURL) }
    private func persistLabels() { persist(labels, to: Self.labelsURL) }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        io.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
