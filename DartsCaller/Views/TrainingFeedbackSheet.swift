import SwiftUI
import UIKit

/// Verschijnt na elke beurt in de AI-trainingsmodus.
/// - "Klopt helemaal": camerabeeld + AI-posities → Positives/
/// - "Foutief": tik de echte pijlpunten aan → score gecorrigeerd, beeld → Needs_Retraining/
struct TrainingFeedbackSheet: View {
    let session: GameSession
    let feedback: GameSession.TurnFeedback

    @Environment(\.dismiss) private var dismiss
    @State private var correcting = false
    @State private var taps: [CGPoint] = []          // posities in mm (correctie)

    private var capture: FrameCapture { feedback.capture }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(correcting
                     ? "Tik de PUNT van elke pijl aan (max. 3). Naast het bord = Mis."
                     : "Klopt wat de AI zag?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                photo
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                scoreRow

                if correcting {
                    HStack {
                        Button("Wis", role: .destructive) { taps.removeAll() }
                            .disabled(taps.isEmpty)
                        Spacer()
                        Button("Annuleer") { correcting = false; taps = [] }
                        Button {
                            session.correctFeedback(pointsMM: taps)
                            dismiss()
                        } label: {
                            Text("Opslaan").frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                } else {
                    HStack(spacing: 12) {
                        Button {
                            correcting = true
                            taps = []
                        } label: {
                            Label("Foutief", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        Button {
                            session.confirmFeedback()
                            dismiss()
                        } label: {
                            Label("Klopt helemaal", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .controlSize(.large)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Beurt van \(feedback.playerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Overslaan") { session.skipFeedback(); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Foto met markeringen

    private var photo: some View {
        GeometryReader { geo in
            let iw = CGFloat(capture.image.width), ih = CGFloat(capture.image.height)
            let scale = min(geo.size.width / iw, geo.size.height / ih)
            let size = CGSize(width: iw * scale, height: ih * scale)
            ZStack(alignment: .topLeading) {
                Image(decorative: capture.image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)

                // Wat de AI zag (rood bij correctie, anders groen)
                ForEach(Array(feedback.darts.enumerated()), id: \.offset) { i, d in
                    if let mm = d.boardPoint, !d.isMiss {
                        marker("\(i + 1)", color: correcting ? .red.opacity(0.6) : .green)
                            .position(toView(mm, scale: scale))
                    }
                }
                // Jouw correctie
                ForEach(Array(taps.enumerated()), id: \.offset) { i, mm in
                    marker("\(i + 1)", color: .yellow)
                        .position(toView(mm, scale: scale))
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard correcting, taps.count < 3 else { return }
                taps.append(toMM(location, scale: scale))
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(CGFloat(capture.image.width) / CGFloat(max(capture.image.height, 1)), contentMode: .fit)
    }

    private func marker(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }

    // MARK: Score

    private var shownDarts: [DartHit] {
        if correcting {
            var hits = taps.map { BoardGeometry.hit(at: $0) }
            while hits.count < 3 { hits.append(.miss) }
            return hits
        }
        return feedback.darts
    }

    private var scoreRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(shownDarts.enumerated()), id: \.offset) { _, d in
                Text(d.shortLabel)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text("= \(shownDarts.reduce(0) { $0 + $1.score })")
                .font(.title3.weight(.semibold).monospacedDigit())
                .frame(minWidth: 60)
        }
    }

    // MARK: Omrekenen  mm ↔ foto

    /// mm → volledig beeld → uitsnede → scherm
    private func toView(_ mm: CGPoint, scale: CGFloat) -> CGPoint {
        let full = capture.boardToImage.apply(mm)
        let k = CGFloat(capture.image.width) / capture.roi.width
        return CGPoint(x: (full.x - capture.roi.minX) * k * scale, y: (full.y - capture.roi.minY) * k * scale)
    }

    /// scherm → uitsnede → volledig beeld → mm
    private func toMM(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        let k = CGFloat(capture.image.width) / capture.roi.width
        let full = CGPoint(x: capture.roi.minX + p.x / scale / k, y: capture.roi.minY + p.y / scale / k)
        return capture.boardToImage.inverse?.apply(full) ?? .zero
    }
}
