import SwiftUI
import UIKit

/// Volledig scherm voor één wedstrijd.
struct GameFlowView: View {
    let config: GameConfig
    @Environment(CameraSystem.self) private var camera
    @Environment(CallerAudioManager.self) private var audio
    @Environment(LearningCenter.self) private var learning
    @Environment(\.dismiss) private var dismiss

    @State private var session: GameSession?
    @State private var cameraDone = false
    @State private var cameraSkipped = false
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Group {
                if config.useCamera && !cameraDone && !cameraSkipped {
                    CameraSetupView(
                        onReady: { cameraDone = true; makeSession(withCamera: true) },
                        onSkip: { camera.pause(); cameraSkipped = true; makeSession(withCamera: false) })
                } else if let session {
                    switch session.stage {
                    case .bullOff:
                        BullOffView(session: session)
                    case .playing, .finished:
                        GameView(session: session, onExit: close, onRematch: rematch)
                    }
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stop") {
                        if session?.stage == .playing { confirmStop = true } else { close() }
                    }
                }
            }
            .confirmationDialog("Wedstrijd stoppen?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop wedstrijd", role: .destructive) { close() }
                Button("Verder spelen", role: .cancel) {}
            } message: {
                Text("De stand gaat verloren.")
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // scherm blijft aan op het statief
            if !config.useCamera { makeSession(withCamera: false) }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session?.end()
            if config.useCamera { camera.pause() }
        }
    }

    private func makeSession(withCamera: Bool) {
        guard session == nil else { return }
        session = GameSession(config: config, audio: audio, camera: withCamera ? camera : nil,
                              learning: withCamera ? learning : nil)
    }

    private func rematch() {
        session?.end()
        session = nil
        makeSession(withCamera: cameraDone)
    }

    private func close() {
        dismiss()
    }
}
