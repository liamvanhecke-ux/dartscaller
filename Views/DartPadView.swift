import SwiftUI
import UIKit

/// Snelle invoer: kies Single/Double/Triple en tik het getal. 25, Bull en Mis apart.
struct DartPadView: View {
    var onSelect: (DartHit) -> Void
    @State private var multiplier = 1

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 10) {
            Picker("Ring", selection: $multiplier) {
                Text("Single").tag(1)
                Text("Double").tag(2)
                Text("Triple").tag(3)
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...20, id: \.self) { n in
                    PadKey(title: prefix + "\(n)", tint: tint) {
                        select(DartHit(segment: n, multiplier: multiplier))
                    }
                }
            }
            HStack(spacing: 8) {
                PadKey(title: "25", tint: .green) { select(.outerBull) }
                PadKey(title: "Bull", tint: .red) { select(.bull) }
                PadKey(title: "Mis", tint: .secondary) { select(.miss) }
            }
        }
    }

    private var prefix: String { multiplier == 3 ? "T" : multiplier == 2 ? "D" : "" }
    private var tint: Color { multiplier == 1 ? .primary : multiplier == 2 ? .green : .red }

    private func select(_ hit: DartHit) {
        onSelect(hit)
        multiplier = 1          // na elke pijl terug naar Single (meest voorkomend)
    }
}

private struct PadKey: View {
    let title: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(tint)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Sheet om één pijl in te voeren of te corrigeren.
struct DartPadSheet: View {
    let title: String
    let current: DartHit?
    var onSelect: (DartHit) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let current {
                    HStack {
                        Text("Nu:").foregroundStyle(.secondary)
                        Text(current.shortLabel).font(.headline.monospacedDigit())
                        Text("(\(current.score))").foregroundStyle(.secondary)
                    }
                }
                DartPadView { hit in
                    onSelect(hit)
                    dismiss()
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
