import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(CallerAudioManager.self) private var audio
    @Environment(CameraSystem.self) private var camera
    @Environment(LearningCenter.self) private var learning
    @State private var export: (url: URL, count: Int)?
    @State private var exportFailed = false
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var audio = audio
        @Bindable var learning = learning
        Form {
            Section {
                Toggle("Caller-stem", isOn: $audio.isEnabled)
                Picker("×3 heet", selection: $audio.multiplierWord) {
                    ForEach(CallerAudioManager.MultiplierWord.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Stem", value: audio.voiceDescription)
                Button("Test de caller") {
                    audio.say("Triple 20. One hundred and eighty! You require one hundred and forty-one.")
                }
                Button("Opnieuw naar stemmen zoeken") { audio.refreshVoice() }
            } header: {
                Text("Caller")
            } footer: {
                if !CallerAudioManager.hasHighQualityVoice {
                    Text("Tip: download een Engelse Premium-stem via Instellingen › Toegankelijkheid › Gesproken materiaal › Stemmen › Engels (VK). Die klinkt veel natuurlijker. Tik daarna op ‘Opnieuw naar stemmen zoeken’.")
                }
            }

            Section {
                LabeledContent("Status", value: camera.calibration == nil ? "Niet ingesteld" : "Gekalibreerd")
                LabeledContent("AI-model (YOLO)", value: camera.hasModel ? "Geladen ✓" : "Niet gevonden — heuristiek")
                if let cal = camera.calibration {
                    LabeledContent("Camerahoek", value: cal.cameraSideDirection == nil ? "Recht voor het bord" : "Schuin ✓")
                }
            } header: {
                Text("AI-camera")
            } footer: {
                Text("Beste resultaat: stevig statief ±1 m van het bord, schuin (30–45°) eronder of ernaast, gelijkmatig licht zonder harde schaduwen. Bij twijfel of een gemiste pijl: tik op het pijlvak om te corrigeren.")
            }

            Section {
                Toggle("Leren van correcties", isOn: $learning.learnFromCorrections)
                LabeledContent("Geleerd", value: "\(learning.learner.correctionCount) correcties · \(learning.learner.confirmationCount) worpen")
                Button("Geleerde correcties wissen", role: .destructive) { learning.resetLearning() }
                    .disabled(learning.learner.observations.isEmpty)
            } header: {
                Text("Zelflerend — direct")
            } footer: {
                Text("Elke correctie (en elke worp die je niet corrigeert) leert de app waar de camera systematisch naast zit. Volgende pijlen in die zone worden meteen bijgestuurd. Wis dit als je de camera verplaatst.")
            }

            Section {
                Toggle("Trainingsfoto's bewaren", isOn: $learning.collectTrainingData)
                LabeledContent("Foto's", value: "\(learning.sampleCount) / \(LearningCenter.maxSamples)")
                if let export {
                    ShareLink(item: export.url) {
                        Label("Deel dataset (\(export.count) foto's)", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task {
                            export = await learning.exportDataset()
                            exportFailed = export == nil
                        }
                    } label: {
                        if learning.isExporting {
                            HStack { ProgressView(); Text("Dataset maken…") }
                        } else {
                            Label("Dataset exporteren", systemImage: "shippingbox")
                        }
                    }
                    .disabled(learning.sampleCount == 0 || learning.isExporting)
                }
                LabeledContent("AI-model", value: camera.modelSource?.rawValue ?? "Geen — heuristiek")
                Button { showImporter = true } label: { Label("Hertraind model importeren", systemImage: "square.and.arrow.down") }
                if camera.modelSource == .custom {
                    Button("Terug naar meegeleverd model", role: .destructive) {
                        LearningCenter.removeCustomModel()
                        Task { await camera.reloadModel() }
                    }
                }
                Button("Trainingsfoto's wissen", role: .destructive) { confirmDelete = true }
                    .disabled(learning.sampleCount == 0)
            } header: {
                Text("Zelflerend — model hertrainen")
            } footer: {
                Text("Elke gedetecteerde pijl wordt een gelabelde foto; gecorrigeerde worpen krijgen het juiste vak. Exporteer → train op je Mac of Colab met Training/train.py → importeer het nieuwe .mlpackage hier. Geen Xcode nodig.")
            }

            Section {
                LabeledContent("Spelvormen", value: "101 · 201 · 301 · 501 · 701")
                LabeledContent("Regels", value: "Double-out, bull = double")
            } header: {
                Text("Over")
            } footer: {
                Text("Pijlherkenning: YOLOv8-model „Dart Sense” door Ben Willshaw (github.com/bnww/dart-sense), licentie CC BY-NC 4.0 — niet voor commercieel gebruik. Getraind o.a. op de DeepDarts-dataset (McNally et al., 2021).")
            }
        }
        .navigationTitle("Instellingen")
        .onAppear { export = nil }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "mlpackage") ?? .folder, .folder, .item]) { result in
            guard case .success(let url) = result else { return }
            importMessage = "Model wordt gecompileerd…"
            Task {
                do {
                    try await LearningCenter.installModel(from: url)
                    await camera.reloadModel()
                    importMessage = camera.modelSource == .custom
                        ? "Nieuw model geladen ✓"
                        : "Model geïmporteerd, maar kon niet geladen worden. Is het geëxporteerd met nms=True?"
                } catch {
                    importMessage = "Importeren mislukt: \(error.localizedDescription)"
                }
            }
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil && importMessage != "Model wordt gecompileerd…" },
                                                          set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) { importMessage = nil }
        }
        .alert("Nog geen bruikbare foto's", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Foto's worden bruikbaar zodra de beurt is afgesloten (volgende speler) of gecorrigeerd.")
        }
        .confirmationDialog("Alle trainingsfoto's wissen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Wissen", role: .destructive) {
                learning.deleteTrainingData()
                export = nil
            }
        }
    }
}
