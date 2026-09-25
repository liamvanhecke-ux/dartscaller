import SwiftUI
import SwiftData

struct NewGameView: View {
    @Query(sort: \Player.name) private var allPlayers: [Player]
    @AppStorage("game.startScore") private var startScore = 501
    @AppStorage("game.doubleOut") private var doubleOut = true
    @AppStorage("game.bullOff") private var useBullOff = true
    @AppStorage("game.camera") private var useCamera = true

    /// Gekozen spelers in speelvolgorde.
    @State private var selectedIDs: [UUID] = []
    @State private var showPicker = false
    @State private var activeGame: GameConfig?

    private var selected: [Player] {
        selectedIDs.compactMap { id in allPlayers.first { $0.uuid == id } }
    }

    var body: some View {
        Form {
            Section("Startscore") {
                Picker("Startscore", selection: $startScore) {
                    ForEach(X01Engine.startOptions, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Double-out", isOn: $doubleOut)
            }

            Section {
                ForEach(Array(selected.enumerated()), id: \.element.uuid) { index, player in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        PlayerAvatar(initials: player.initials, size: 32)
                        Text(player.displayName)
                    }
                }
                .onMove { from, to in selectedIDs.move(fromOffsets: from, toOffset: to) }
                .onDelete { offsets in
                    let ids = offsets.map { selected[$0].uuid }
                    selectedIDs.removeAll { ids.contains($0) }
                }

                Button {
                    showPicker = true
                } label: {
                    Label(selected.isEmpty ? "Spelers kiezen" : "Spelers aanpassen", systemImage: "person.crop.circle.badge.plus")
                }
            } header: {
                Text("Spelers & volgorde")
            } footer: {
                if selected.count > 1 { Text("Houd een speler vast en sleep, of tik op Wijzig, om de volgorde te veranderen.") }
            }

            Section {
                Toggle(isOn: $useBullOff) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bull-off")
                        Text("Elke speler gooit 1 pijl; dichtst bij de roos begint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(selected.count < 2)
                Toggle(isOn: $useCamera) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI-camera")
                        Text("Automatisch scoren. Uit = handmatige invoer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(action: start) {
                    Text("Start wedstrijd")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Nieuwe wedstrijd")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton().disabled(selected.count < 2)
            }
        }
        .sheet(isPresented: $showPicker) { PlayerPickerSheet(selectedIDs: $selectedIDs) }
        .fullScreenCover(item: $activeGame) { GameFlowView(config: $0) }
        .onChange(of: allPlayers.map(\.uuid)) { _, ids in
            selectedIDs.removeAll { !ids.contains($0) }   // verwijderde spelers uit selectie halen
        }
    }

    private func start() {
        guard !selected.isEmpty else { return }
        activeGame = GameConfig(
            players: selected.map { GamePlayer(id: $0.uuid, name: $0.displayName) },
            startScore: startScore,
            doubleOut: doubleOut,
            bullOff: useBullOff && selected.count >= 2,
            useCamera: useCamera)
    }
}

struct PlayerPickerSheet: View {
    @Binding var selectedIDs: [UUID]
    @Query(sort: \Player.name) private var players: [Player]
    @Environment(\.dismiss) private var dismiss
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(players) { player in
                    Button {
                        toggle(player.uuid)
                    } label: {
                        HStack {
                            PlayerRow(player: player)
                            if let i = selectedIDs.firstIndex(of: player.uuid) {
                                Text("\(i + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.accentColor))
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary).font(.title3)
                            }
                        }
                    }
                    .tint(.primary)
                }
                Button { showingNew = true } label: { Label("Nieuwe speler", systemImage: "plus") }
            }
            .navigationTitle("Kies spelers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } }
            }
            .sheet(isPresented: $showingNew) { PlayerEditorSheet(player: nil) }
        }
    }

    private func toggle(_ id: UUID) {
        if let i = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: i) } else { selectedIDs.append(id) }
    }
}
