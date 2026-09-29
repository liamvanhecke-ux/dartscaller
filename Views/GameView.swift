import SwiftUI
import UIKit

struct GameView: View {
    let session: GameSession
    var onExit: () -> Void
    var onRematch: () -> Void

    @State private var padTarget: PadTarget?
    @State private var showHistory = false
    @State private var showCameraFeed = true

    private var engine: X01Engine { session.engine }

    struct PadTarget: Identifiable {
        let slot: Int
        var id: Int { slot }
    }

    var body: some View {
        VStack(spacing: 12) {
            PlayersStrip(engine: engine)
            scorePanel
            if session.usesCamera {
                boardPanel
            } else {
                DartPadView { session.registerManual($0) }
                    .disabled(engine.phase != .throwing)
                    .opacity(engine.phase == .throwing ? 1 : 0.4)
                Spacer(minLength: 0)
            }
            dartSlots
            controls
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("\(engine.startScore) · \(engine.doubleOut ? "Double-out" : "Single-out")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .overlay(alignment: .top) { toastView }
        .sheet(item: $padTarget) { target in
            DartPadSheet(title: "Pijl \(target.slot + 1)", current: dart(at: target.slot)) { hit in
                if engine.phase == .throwing && target.slot == engine.turn.count {
                    session.registerManual(hit)
                } else {
                    session.setDart(slot: target.slot, to: hit)
                }
            }
        }
        .sheet(isPresented: $showHistory) { TurnHistorySheet(session: session) }
        .sheet(isPresented: Binding(get: { session.stage == .finished }, set: { _ in })) {
            GameOverView(session: session, onExit: onExit, onRematch: onRematch)
        }
    }

    // MARK: - Onderdelen

    private var scorePanel: some View {
        VStack(spacing: 2) {
            Text(engine.currentSeat.name)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(engine.liveRemaining)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: Double(engine.liveRemaining)))
                .animation(.snappy, value: engine.liveRemaining)
            infoCapsule
                .frame(minHeight: 30)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var infoCapsule: some View {
        if engine.phase == .throwing {
            if let route = CheckoutCalculator.suggestion(for: engine.liveRemaining, dartsLeft: engine.dartsLeftInTurn, doubleOut: engine.doubleOut) {
                Label(CheckoutCalculator.label(for: route), systemImage: "scope")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            } else if engine.liveRemaining <= 170 && engine.doubleOut {
                Text("Geen finish met \(engine.dartsLeftInTurn) \(engine.dartsLeftInTurn == 1 ? "pijl" : "pijlen")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else if let last = engine.records.last {
            Group {
                switch last.outcome {
                case .bust: Text("BUST").foregroundStyle(.red)
                case .checkout: Text("GAME SHOT").foregroundStyle(.green)
                case .scored: Text("Beurt: \(last.countedPoints)")
                }
            }
            .font(.headline)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
    }

    private var boardPanel: some View {
        ZStack(alignment: .topTrailing) {
            BoardView(markers: BoardMarker.forDarts(engine.visibleDarts))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
            if showCameraFeed, let cam = session.camera {
                CameraPreview(session: cam.controller.session, fill: true)
                    .frame(width: 92, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1))
                    .shadow(radius: 4)
                    .onTapGesture { showCameraFeed = false }
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomLeading) { statusPill.padding(8) }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var statusPill: some View {
        let (text, color, icon): (String, Color, String) = {
            if session.playerAtBoard { return ("Speler bij het bord — haal de pijlen eruit", .orange, "figure.walk") }
            switch engine.phase {
            case .throwing: return ("Wacht op pijl \(engine.turn.count + 1)", .green, "dot.radiowaves.left.and.right")
            case .awaitingNext: return ("Haal de pijlen uit het bord", .blue, "hand.raised")
            case .finished: return ("Leg voorbij", .secondary, "flag.checkered")
            }
        }()
        return Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(color)
    }

    private var dartSlots: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { i in
                let d = dart(at: i)
                Button {
                    padTarget = PadTarget(slot: i)
                } label: {
                    VStack(spacing: 2) {
                        Text(d?.shortLabel ?? "–")
                            .font(.title3.weight(.bold).monospacedDigit())
                        Text(d.map { "\($0.score)" } ?? " ")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isNextSlot(i) ? Color.accentColor : .clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isEditable(i))
                .accessibilityLabel("Pijl \(i + 1): \(d?.shortLabel ?? "leeg")")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                session.undo()
            } label: {
                Label("Ongedaan", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 30)
            }
            .buttonStyle(.bordered)
            .disabled(engine.turn.isEmpty && engine.records.isEmpty)
            .accessibilityLabel("Laatste pijl ongedaan maken")

            switch engine.phase {
            case .throwing:
                Button {
                    session.registerManual(.miss)
                } label: {
                    Text("Mis").frame(minWidth: 40)
                }
                .buttonStyle(.bordered)
                Button {
                    session.confirmTurn()
                } label: {
                    Text(engine.turn.isEmpty ? "3× mis" : "Beurt bevestigen")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .awaitingNext:
                Button {
                    session.nextPlayer()
                } label: {
                    Text("Volgende speler").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .finished:
                Spacer()
            }
        }
        .controlSize(.large)
        .sensoryFeedback(.impact(weight: .light), trigger: engine.records.count)
    }

    private var menu: some View {
        Menu {
            Button { showHistory = true } label: { Label("Beurten & correcties", systemImage: "list.bullet.rectangle") }
            Button {
                session.audio.isEnabled.toggle()
            } label: {
                Label(session.audio.isEnabled ? "Caller uit" : "Caller aan",
                      systemImage: session.audio.isEnabled ? "speaker.slash" : "speaker.wave.2")
            }
            if session.usesCamera {
                Button {
                    showCameraFeed.toggle()
                } label: {
                    Label(showCameraFeed ? "Camerabeeld verbergen" : "Camerabeeld tonen", systemImage: "video")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = session.toast {
            Label(toast, systemImage: toast.hasPrefix("Geleerd") ? "sparkles" : "figure.walk")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Hulp

    private func dart(at slot: Int) -> DartHit? {
        let darts = engine.visibleDarts
        return slot < darts.count ? darts[slot] : nil
    }

    private func isNextSlot(_ i: Int) -> Bool {
        engine.phase == .throwing && i == engine.turn.count
    }

    private func isEditable(_ i: Int) -> Bool {
        guard engine.phase != .finished else { return false }
        return i <= engine.visibleDarts.count && i < 3
    }
}

// MARK: - Spelers bovenaan

struct PlayersStrip: View {
    let engine: X01Engine

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(engine.seats.enumerated()), id: \.element.id) { index, seat in
                        card(seat, index: index)
                            .id(seat.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: engine.current) { _, new in
                withAnimation { proxy.scrollTo(engine.seats[new].id, anchor: .center) }
            }
        }
    }

    private func card(_ seat: X01Engine.Seat, index: Int) -> some View {
        let active = index == engine.current
        return VStack(alignment: .leading, spacing: 2) {
            Text(seat.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(seat.remaining)")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text("Ø \(engine.threeDartAverage(for: index).formatted(.number.precision(.fractionLength(1))))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 96, alignment: .leading)
        .background(active ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(active ? Color.accentColor : .clear, lineWidth: 2))
    }
}
