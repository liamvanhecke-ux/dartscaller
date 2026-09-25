import SwiftUI
import UIKit

struct BullOffView: View {
    let session: GameSession
    @State private var showManual = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("Bull-off").font(.largeTitle.bold())
                    Text("Elke speler gooit 1 pijl. Dichtst bij de roos begint.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if session.usesCamera {
                    BoardView(markers: markers)
                        .frame(maxWidth: 340)
                        .padding(.horizontal)
                }

                VStack(spacing: 0) {
                    ForEach(session.config.players) { player in
                        row(player)
                        if player.id != session.config.players.last?.id { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                resultCard

                Button("Zelf kiezen wie begint") { showManual = true }
                    .font(.callout)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .confirmationDialog("Wie begint?", isPresented: $showManual, titleVisibility: .visible) {
            ForEach(session.config.players) { p in
                Button(p.name) { session.chooseStarter(p.id) }
            }
        }
        .onAppear { if !session.usesCamera { showManual = true } }
    }

    private var markers: [BoardMarker] {
        session.config.players.compactMap { p in
            guard let hit = session.bullOffHits[p.id], let point = hit.boardPoint, !hit.isMiss else { return nil }
            let initials = p.name.split(separator: " ").compactMap { $0.first }.prefix(2).map { String($0) }.joined()
            var emphasized = false
            if case .decided(let id) = session.bullOffState { emphasized = id == p.id }
            return BoardMarker(id: p.id, point: point, label: initials.uppercased(), emphasized: emphasized)
        }
    }

    private func row(_ player: GamePlayer) -> some View {
        HStack {
            Text(player.name).font(.body.weight(.medium))
            Spacer()
            Text(status(for: player))
                .font(.body.monospacedDigit())
                .foregroundStyle(session.bullOffCurrent?.id == player.id ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func status(for player: GamePlayer) -> String {
        if let hit = session.bullOffHits[player.id] {
            guard !hit.isMiss, let mm = hit.distanceToCenterMM else { return "Mis" }
            return "\(mm.formatted(.number.precision(.fractionLength(1)))) mm"
        }
        if session.bullOffCurrent?.id == player.id { return session.usesCamera ? "Aan de beurt" : "—" }
        if session.bullOffThrowers.contains(where: { $0.id == player.id }) { return "Wacht" }
        return "—"
    }

    @ViewBuilder
    private var resultCard: some View {
        switch session.bullOffState {
        case .throwing:
            if let current = session.bullOffCurrent, session.usesCamera {
                Label("\(current.name), gooi op de roos", systemImage: "scope")
                    .font(.headline)
            }
        case .decided(let id):
            VStack(spacing: 10) {
                Label("\(session.name(of: id)) begint!", systemImage: "trophy.fill")
                    .font(.title3.weight(.semibold))
                Text("Haal de pijlen uit het bord; de wedstrijd start vanzelf.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Start nu") { session.startMatch(winner: id) }
                    .buttonStyle(.borderedProminent)
            }
        case .rethrow(let ids):
            VStack(spacing: 10) {
                Label("Gelijk — opnieuw gooien", systemImage: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.semibold))
                Text(ids.map { session.name(of: $0) }.joined(separator: " en "))
                    .foregroundStyle(.secondary)
                Button("Opnieuw gooien") { session.startRethrow(ids) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
