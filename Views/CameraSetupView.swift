import SwiftUI
import UIKit

struct CameraSetupView: View {
    var onReady: () -> Void
    var onSkip: () -> Void

    @Environment(CameraSystem.self) private var camera
    @State private var offerReuse = false
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .navigationTitle("Camera instellen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            guard !started else { return }
            started = true
            if camera.isReady { offerReuse = true } else { Task { await camera.beginSetup() } }
        }
        .onChange(of: camera.step) { _, step in
            if step == .ready && !offerReuse { onReady() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if offerReuse {
            reuseCard
        } else {
            switch camera.step {
            case .idle:
                ProgressView().tint(.white)
            case .denied:
                MessageCard(icon: "camera.fill", title: "Geen toegang tot de camera",
                            text: "Geef toegang via Instellingen › DartsCaller › Camera, of speel met handmatige invoer.") {
                    Button("Open Instellingen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.borderedProminent)
                    Button("Zonder camera spelen", action: onSkip)
                }
            case .failed(let message):
                MessageCard(icon: "exclamationmark.triangle.fill", title: "Camera werkt niet", text: message) {
                    Button("Opnieuw proberen") { Task { await camera.beginSetup() } }.buttonStyle(.borderedProminent)
                    Button("Zonder camera spelen", action: onSkip)
                }
            case .searching, .zooming, .focusing:
                live(status: statusText, busy: true) {
                    Button("Zelf aanduiden") { camera.calibrateManually() }
                        .buttonStyle(.bordered).tint(.white)
                }
            case .searchFailed:
                live(status: "Geen dartbord gevonden. Richt de camera zodat het hele bord in beeld is.", busy: false) {
                    HStack {
                        Button("Opnieuw zoeken") { camera.retrySearch() }.buttonStyle(.borderedProminent)
                        Button("Zelf aanduiden") { camera.calibrateManually() }.buttonStyle(.bordered).tint(.white)
                    }
                }
            case .calibrating:
                CalibrationView()
            case .waitingForBaseline:
                live(status: "Zet de iPhone stil (statief), haal alle pijlen uit het bord en ga uit beeld. Het lege bord wordt vastgelegd…", busy: true) {
                    BaselineFallbackButton { camera.captureBaselineNow() }
                }
            case .ready:
                live(status: "Klaar!", busy: false) { EmptyView() }
            }
        }
    }

    private var statusText: String {
        switch camera.step {
        case .zooming: return "Bord gevonden — inzoomen…"
        case .focusing: return "Scherpstellen en belichting vastzetten…"
        default: return "Dartbord zoeken…"
        }
    }

    private var reuseCard: some View {
        MessageCard(icon: "checkmark.circle.fill", title: "Camera staat nog klaar",
                    text: "Is de camera niet verplaatst sinds de vorige wedstrijd? Dan kun je de kalibratie hergebruiken.") {
            Button("Kalibratie hergebruiken") {
                camera.resume()
                onReady()
            }.buttonStyle(.borderedProminent)
            Button("Punten controleren") {
                offerReuse = false
                camera.recalibrate()
            }
            Button("Opnieuw instellen") {
                offerReuse = false
                Task { await camera.beginSetup() }
            }
        }
    }

    private func live<Actions: View>(status: String, busy: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.controller.session)
                .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(.white) }
                    Text(status).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                }
                if camera.step == .searching {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Stevig statief, ±1 m van het bord", systemImage: "camera.metering.center.weighted")
                        Label("Schuin (30–45°), onder of naast het bord", systemImage: "arrow.up.left.and.arrow.down.right")
                        Label("Gelijkmatig licht, bord leeg", systemImage: "lightbulb")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                }
                actions()
            }
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding()
        }
    }
}

/// Verschijnt na 4 seconden: lukt het automatisch niet, dan kan de gebruiker zelf vastleggen.
private struct BaselineFallbackButton: View {
    let action: () -> Void
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                VStack(spacing: 6) {
                    Button("Leeg bord nu vastleggen", action: action)
                        .buttonStyle(.borderedProminent)
                    Text("Lukt het niet? Staat de iPhone echt stil en is er niemand in beeld?")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { visible = true }
        }
    }
}

// MARK: - Kalibratie

/// Omrekening tussen beeldpixels en schermpunten bij "aspect fit".
struct FitTransform {
    let scale: CGFloat
    let size: CGSize

    init(imageSize: CGSize, container: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { scale = 1; size = .zero; return }
        scale = min(container.width / imageSize.width, container.height / imageSize.height)
        size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }
}

struct CalibrationView: View {
    @Environment(CameraSystem.self) private var camera
    @State private var activeHandle: Int?
    @State private var dragStart: CGPoint?
    @State private var showError = false

    private let loupeSize: CGFloat = 120
    private let loupeZoom: CGFloat = 3

    var body: some View {
        VStack(spacing: 12) {
            Text("Sleep elk punt naar de **buitenrand van de double-ring**, precies op de draad tussen de aangegeven nummers. De gele lijnen moeten over het bord vallen.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal)

            if let image = camera.snapshot {
                GeometryReader { geo in
                    let fit = FitTransform(imageSize: camera.imageSize, container: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: fit.size.width, height: fit.size.height)
                        overlay(fit: fit)
                        ForEach(0..<camera.calibrationPoints.count, id: \.self) { i in
                            handle(i, fit: fit)
                        }
                        if let i = activeHandle, i < camera.calibrationPoints.count {
                            loupe(image: image, at: fit.toView(camera.calibrationPoints[i]), fit: fit)
                        }
                    }
                    .frame(width: fit.size.width, height: fit.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            }

            angleHint

            Button {
                camera.refineNow()
            } label: {
                if camera.isRefining {
                    HStack { ProgressView().tint(.white); Text("Verfijnen…") }
                } else {
                    Label("Verfijn automatisch", systemImage: "scope")
                }
            }
            .buttonStyle(.bordered).tint(.white)
            .disabled(camera.isRefining)

            HStack(spacing: 12) {
                Button("Opnieuw zoeken") { camera.retrySearch() }
                    .buttonStyle(.bordered).tint(.white)
                Button {
                    if !camera.confirmCalibration() { showError = true }
                } label: {
                    Text("Bevestigen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(camera.previewCalibration == nil)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom])
        }
        .alert("Deze punten vormen geen geldig bord", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var angleHint: some View {
        if let info = camera.refineInfo {
            Label("Automatisch verfijnd: \(info.edgePoints) meetpunten, fout \(String(format: "%.1f", info.rmsErrorPx)) px"
                  + (info.bullOffsetMM.map { ", bull ±\(String(format: "%.1f", $0)) mm" } ?? ""),
                  systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else if camera.pointsFoundByModel {
            Label("Punten gevonden door de AI — controleer en bevestig.", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.cyan)
        }
        if let cal = camera.previewCalibration {
            if cal.cameraSideDirection == nil {
                Label("De camera staat bijna recht voor het bord. Zet hem schuin (30–45°): dan vindt de app de pijlpunt veel beter.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.yellow).padding(.horizontal)
            } else {
                Label("Camerahoek is goed.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        } else {
            Label("De punten vormen nog geen geldig bord.", systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    /// Live projectie van het bord met de huidige punten: directe controle van de kalibratie.
    private func overlay(fit: FitTransform) -> some View {
        Canvas { ctx, _ in
            guard let cal = camera.previewCalibration else { return }
            func view(_ mm: CGPoint) -> CGPoint { fit.toView(cal.toImage.apply(mm)) }
            let yellow = GraphicsContext.Shading.color(.yellow.opacity(0.9))
            for r in [BoardGeometry.outerBullR, BoardGeometry.trebleInR, BoardGeometry.trebleOutR,
                      BoardGeometry.doubleInR, BoardGeometry.doubleOutR] {
                var p = Path()
                for k in 0...72 {
                    let a = Double(k) * 5 * .pi / 180
                    let q = view(CGPoint(x: r * cos(a), y: r * sin(a)))
                    if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
                }
                ctx.stroke(p, with: yellow, lineWidth: 1)
            }
            for k in 0..<20 {
                let a = (99 - Double(k) * 18) * .pi / 180
                var p = Path()
                p.move(to: view(CGPoint(x: BoardGeometry.outerBullR * cos(a), y: BoardGeometry.outerBullR * sin(a))))
                p.addLine(to: view(CGPoint(x: BoardGeometry.doubleOutR * cos(a), y: BoardGeometry.doubleOutR * sin(a))))
                ctx.stroke(p, with: yellow, lineWidth: 0.8)
            }
            let c = view(.zero)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.yellow))
        }
        .frame(width: fit.size.width, height: fit.size.height)
        .allowsHitTesting(false)
    }

    private func handle(_ i: Int, fit: FitTransform) -> some View {
        let p = fit.toView(camera.calibrationPoints[i])
        let active = activeHandle == i
        return ZStack {
            Circle().fill(Color.accentColor.opacity(active ? 0.35 : 0.2))
            Circle().stroke(.white, lineWidth: 2)
            Circle().fill(.white).frame(width: 4, height: 4)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .top) {
            Text(BoardGeometry.calibrationLabels[i])
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .fixedSize()
                .offset(y: -24)
        }
        .contentShape(Circle().inset(by: -12))
        .position(p)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = camera.calibrationPoints[i]
                        activeHandle = i
                    }
                    guard let start = dragStart, fit.scale > 0 else { return }
                    let x = start.x + value.translation.width / fit.scale
                    let y = start.y + value.translation.height / fit.scale
                    camera.calibrationPoints[i] = CGPoint(
                        x: min(max(0, x), camera.imageSize.width),
                        y: min(max(0, y), camera.imageSize.height))
                }
                .onEnded { _ in
                    dragStart = nil
                    activeHandle = nil
                }
        )
    }

    /// Vergrootglas boven de vinger zodat je het punt exact op de draad kan leggen.
    private func loupe(image: CGImage, at p: CGPoint, fit: FitTransform) -> some View {
        let d = loupeSize, z = loupeZoom
        let y = p.y - d * 0.5 - 40 < d / 2 ? p.y + d * 0.5 + 40 : p.y - d * 0.5 - 40
        let x = min(max(d / 2, p.x), fit.size.width - d / 2)
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: fit.size.width * z, height: fit.size.height * z)
            .offset(x: d / 2 - p.x * z, y: d / 2 - p.y * z)
            .frame(width: d, height: d, alignment: .topLeading)
            .clipShape(Circle())
            .overlay {
                ZStack {
                    Rectangle().fill(.red).frame(width: 1, height: 18)
                    Rectangle().fill(.red).frame(width: 18, height: 1)
                }
            }
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 6)
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }
}

// MARK: - Herbruikbare kaart

struct MessageCard<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tint)
            Text(title).font(.title3.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 10) { actions }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
        .environment(\.colorScheme, .dark)
    }
}
