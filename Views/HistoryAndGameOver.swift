import SwiftUI
import SwiftData
import UIKit

// MARK: - Beurtgeschiedenis

struct TurnHistorySheet: View {
    let session: GameSession
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TurnRecord?

    private var engine: X01Engine { session.engine }

    var body: some View {
        NavigationStack {
            List {
                ForEach(engine.records.reversed()) { record in
                    Button { editing = record } label: { row(record) }
                        .tint(.primary)
                }
            }
            .overlay {
                if engine.records.isEmpty {
                    ContentUnavailableView("Nog geen beurten", systemImage: "list.bullet.rectangle")
                }
            }
            .navigationTitle("Beurten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } }
            }
            .sheet(item: $editing) { record in
                TurnEditorSheet(record: record, playerName: engine.seats[record.seatIndex].name) { darts in
                    session.amend(record.id, darts: darts)
                }
            }
        }
    }

    private func row(_ r: TurnRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.seats[r.seatIndex].name).font(.subheadline.weight(.semibold))
                Text(r.darts.map(\.shortLabel).joined(separator: "  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                switch r.outcome {
                case .bust: Text("Bust").foregroundStyle(.red).font(.headline)
                case .checkout: Text("Game shot").foregroundStyle(.green).font(.headline)
                case .scored: Text("\(r.countedPoints)").font(.headline.monospacedDigit())
                }
                Text("rest \(r.endRemaining)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Image(systemName: "pencil").foregroundStyle(.tertiary)
        }
    }
}

struct TurnEditorSheet: View {
    let playerName: String
    let onSave: ([DartHit]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var darts: [DartHit]
    @State private var selected = 0

    init(record: TurnRecord, playerName: String, onSave: @escaping ([DartHit]) -> Void) {
        self.playerName = playerName
        self.onSave = onSave
        var d = record.darts
        while d.count < 3 { d.append(.miss) }
        _darts = State(initialValue: d)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        Button { selected = i } label: {
                            VStack(spacing: 2) {
                                Text(darts[i].shortLabel).font(.title3.weight(.bold).monospacedDigit())
                                Text("\(darts[i].score)").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(selected == i ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Totaal \(darts.reduce(0) { $0 + $1.score })")
                    .font(.headline.monospacedDigit())
                DartPadView { hit in
                    darts[selected] = hit
                    if selected < 2 { selected += 1 }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Beurt van \(playerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaar") {
                        onSave(darts)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Einde van de leg

struct GameOverView: View {
    let session: GameSession
    var onExit: () -> Void
    var onRematch: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var players: [Player]

    private var engine: X01Engine { session.engine }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow.gradient)
                        .padding(.top, 24)
                    VStack(spacing: 4) {
                        Text(engine.winner?.name ?? "").font(.largeTitle.bold())
                        Text("wint de leg").font(.title3).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(engine.seats.enumerated()), id: \.element.id) { i, seat in
                            HStack {
                                Text(seat.name).font(.body.weight(.medium))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Ø \(engine.threeDartAverage(for: i).formatted(.number.precision(.fractionLength(2))))")
                                        .font(.body.monospacedDigit().weight(.semibold))
                                    Text("\(engine.dartsThrown(by: i)) pijlen · rest \(seat.remaining)")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            if i < engine.seats.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(spacing: 10) {
                        Button {
                            recordStats()
                            onRematch()
                        } label: {
                            Text("Nieuwe leg").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            recordStats()
                            onExit()
                        } label: {
                            Text("Klaar").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button("Laatste pijl corrigeren") { session.undo() }
                            .font(.callout)
                            .padding(.top, 4)
                    }
                    .controlSize(.large)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        }
        .interactiveDismissDisabled()
    }

    private func recordStats() {
        guard !session.statsRecorded else { return }
        session.statsRecorded = true
        for (i, seat) in engine.seats.enumerated() {
            guard let player = players.first(where: { $0.uuid == seat.id }) else { continue }
            player.gamesPlayed += 1
            if engine.winnerIndex == i { player.gamesWon += 1 }
            let avg = engine.threeDartAverage(for: i)
            if avg > player.bestAverage { player.bestAverage = avg }
        }
        try? context.save()
    }
}
