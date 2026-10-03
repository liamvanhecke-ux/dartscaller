import SwiftUI
import SwiftData

struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Player.name) private var players: [Player]
    @State private var editing: Player?
    @State private var showingNew = false

    var body: some View {
        List {
            ForEach(players) { player in
                Button { editing = player } label: { PlayerRow(player: player) }
                    .tint(.primary)
            }
            .onDelete { offsets in
                for i in offsets { context.delete(players[i]) }
                try? context.save()
            }
        }
        .overlay {
            if players.isEmpty {
                ContentUnavailableView {
                    Label("Nog geen spelers", systemImage: "person.badge.plus")
                } description: {
                    Text("Voeg spelers toe om een wedstrijd te starten.")
                } actions: {
                    Button("Speler toevoegen") { showingNew = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Spelers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: { Label("Nieuwe speler", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) { PlayerEditorSheet(player: nil) }
        .sheet(item: $editing) { PlayerEditorSheet(player: $0) }
    }
}

struct PlayerAvatar: View {
    let initials: String
    var size: CGFloat = 40

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.gradient))
    }
}

struct PlayerRow: View {
    let player: Player

    var body: some View {
        HStack(spacing: 12) {
            PlayerAvatar(initials: player.initials)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayName).font(.body.weight(.semibold))
                Text(stats).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var stats: String {
        if player.gamesPlayed == 0 { return "Nog geen wedstrijden" }
        let avg = player.bestAverage.formatted(.number.precision(.fractionLength(1)))
        return "\(player.gamesPlayed) gespeeld · \(player.gamesWon) gewonnen · beste gem. \(avg)"
    }
}

struct PlayerEditorSheet: View {
    let player: Player?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nickname = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Naam", text: $name)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                    TextField("Bijnaam (optioneel)", text: $nickname)
                        .autocorrectionDisabled()
                } footer: {
                    Text("De naam wordt gebruikt in de caller: \"… to throw first\".")
                }
                if let player, player.gamesPlayed > 0 {
                    Section("Statistieken") {
                        LabeledContent("Gespeeld", value: "\(player.gamesPlayed)")
                        LabeledContent("Gewonnen", value: "\(player.gamesWon)")
                        LabeledContent("Beste 3-dart gemiddelde",
                                       value: player.bestAverage.formatted(.number.precision(.fractionLength(1))))
                    }
                }
            }
            .navigationTitle(player == nil ? "Nieuwe speler" : "Speler bewerken")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaar") { save() }.disabled(trimmedName.isEmpty)
                }
            }
            .onAppear {
                name = player?.name ?? ""
                nickname = player?.nickname ?? ""
            }
        }
    }

    private func save() {
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if let player {
            player.name = trimmedName
            player.nickname = nick
        } else {
            context.insert(Player(name: trimmedName, nickname: nick))
        }
        try? context.save()
        dismiss()
    }
}
