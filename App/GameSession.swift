import Foundation
import Observation

/// Eén wedstrijd: bull-off → spel → einde. Alle invoer (camera én handmatig) loopt hierlangs.
@Observable
@MainActor
final class GameSession {

    enum Stage: Equatable { case bullOff, playing, finished }

    enum BullOffState: Equatable {
        case throwing
        case decided(UUID)
        case rethrow([UUID])
    }

    let config: GameConfig
    let audio: CallerAudioManager
    let camera: CameraSystem?
    /// Zelflerend systeem (alleen met camera).
    let learning: LearningCenter?

    private(set) var engine: X01Engine
    private(set) var stage: Stage
    private(set) var order: [GamePlayer]

    // Bull-off
    private(set) var bullOffThrowers: [GamePlayer]
    private(set) var bullOffIndex = 0
    private(set) var bullOffHits: [UUID: DartHit] = [:]
    private(set) var bullOffState: BullOffState = .throwing

    // Status voor de UI
    private(set) var playerAtBoard = false
    private(set) var toast: String? = nil
    @ObservationIgnored private var toastTask: Task<Void, Never>? = nil
    @ObservationIgnored var statsRecorded = false

    var usesCamera: Bool { camera != nil }

    init(config: GameConfig, audio: CallerAudioManager, camera: CameraSystem?, learning: LearningCenter? = nil) {
        self.config = config
        self.audio = audio
        self.camera = camera
        self.learning = camera == nil ? nil : learning
        self.order = config.players
        self.bullOffThrowers = config.players
        self.engine = X01Engine(players: config.players.map { (id: $0.id, name: $0.name) },
                                startScore: config.startScore, doubleOut: config.doubleOut)
        self.stage = (config.bullOff && config.players.count >= 2) ? .bullOff : .playing
        wireEngine()
        camera?.eventHandler = { [weak self] event in self?.handle(event) }
        if stage == .bullOff {
            camera?.pipeline.setMode(.bullOff)
        } else {
            camera?.pipeline.startGameMode()
        }
    }

    func end() {
        camera?.eventHandler = nil
        camera?.pipeline.setMode(.off)
        audio.stop()
        toastTask?.cancel()
    }

    func name(of id: UUID) -> String {
        config.players.first { $0.id == id }?.name ?? "?"
    }

    // MARK: - Engine → audio / camera

    private func wireEngine() {
        engine.onEvent = { [weak self] event in self?.engineEvent(event) }
    }

    private func engineEvent(_ event: GameEvent) {
        switch event {
        case .dart(let hit):
            audio.announceDart(hit)
        case .turnEnded(let record):
            audio.announceTurn(record, won: engine.phase == .finished)
            camera?.pipeline.lockTurn()
        case .turnCorrected(let record):
            if record.id == engine.records.last?.id {
                audio.announceCorrection(record)
            } else {
                audio.say("Correction.")
            }
        case .legWon:
            stage = .finished
            camera?.pipeline.setMode(.off)
            learning?.confirm(engine.records.last?.darts ?? [])
        }
    }

    // MARK: - Camera → spel

    func handle(_ event: VisionEvent) {
        switch event {
        case .dart(let hit, _, _, let capture):
            playerAtBoard = false
            switch stage {
            case .bullOff:
                registerBullOff(hit)
            case .playing:
                guard engine.phase == .throwing else { break }
                // Geleerde correctie toepassen + beeld bewaren voor training
                let dart = learning?.adjust(hit, capture: capture, dartsInBoard: engine.turn) ?? hit
                engine.register(dart)
            case .finished:
                break
            }

        case .playerAtBoard(let counted, let wasLocked, let reason):
            playerAtBoard = true
            switch stage {
            case .bullOff:
                bullOffPlayerAtBoard()
            case .playing:
                // Specificatie: speler bij het bord en nog geen 3 pijlen → rest = MIS, beurt dicht.
                // Niet bij een vergrendelde beurt, en niet als alleen oude pijlen verdwijnen (0 getelde pijlen).
                let fill = engine.phase == .throwing && !wasLocked && (reason == .person || counted > 0)
                if fill {
                    let missing = engine.dartsLeftInTurn
                    engine.completeTurnWithMisses()
                    showToast(missing == 1 ? "1 pijl niet gezien → Mis" : "\(missing) pijlen niet gezien → Mis")
                }
            case .finished:
                break
            }

        case .boardCleared:
            playerAtBoard = false
            switch stage {
            case .bullOff: bullOffBoardCleared()
            case .playing:
                if engine.phase == .awaitingNext {
                    learning?.confirm(engine.records.last?.darts ?? [])   // niet gecorrigeerd = juist
                    engine.nextPlayer()
                }
            case .finished: break
            }

        case .boardFound, .baselineCaptured:
            break
        }
    }

    // MARK: - Handmatige invoer & correcties

    /// Volgende pijl handmatig invoeren.
    func registerManual(_ hit: DartHit) {
        guard engine.phase == .throwing else { return }
        engine.register(hit)
        if engine.phase == .throwing { camera?.pipeline.setDartsCounted(engine.turn.count) }
    }

    /// Pijl `slot` (0...2) van de zichtbare beurt aanpassen of toevoegen.
    func setDart(slot: Int, to hit: DartHit) {
        let old = slot < engine.visibleDarts.count ? engine.visibleDarts[slot] : nil
        let wasThrowing = engine.phase == .throwing
        if wasThrowing {
            engine.setCurrentDart(at: slot, to: hit)
        } else if let last = engine.records.last {
            var darts = last.darts
            if slot < darts.count { darts[slot] = hit } else { darts.append(hit) }
            engine.amendTurn(id: last.id, darts: darts)
        }
        afterEdit(wasThrowing: wasThrowing)
        if let old, learning?.corrected(old: old, new: hit) == true {
            showToast("Geleerd van je correctie ✓")
        }
    }

    /// Een oudere beurt corrigeren (uit de geschiedenis).
    func amend(_ recordID: TurnRecord.ID, darts: [DartHit]) {
        let old = engine.records.first { $0.id == recordID }?.darts ?? []
        let wasThrowing = engine.phase == .throwing
        engine.amendTurn(id: recordID, darts: darts)
        afterEdit(wasThrowing: wasThrowing)
        var learned = false
        for (o, n) in zip(old, darts) where o.id != n.id {
            if learning?.corrected(old: o, new: n) == true { learned = true }
        }
        if learned { showToast("Geleerd van je correctie ✓") }
    }

    func undo() {
        let wasThrowing = engine.phase == .throwing
        let last = wasThrowing ? (engine.turn.last ?? engine.records.last?.darts.last) : engine.records.last?.darts.last
        if let last { learning?.removed(last) }
        engine.undoLastDart()
        afterEdit(wasThrowing: wasThrowing)
    }

    /// "Beurt bevestigen": ontbrekende pijlen = mis.
    func confirmTurn() {
        engine.completeTurnWithMisses()
    }

    /// "Volgende speler" (als de camera het lege bord niet zelf ziet, of zonder camera).
    func nextPlayer() {
        guard engine.phase == .awaitingNext else { return }
        learning?.confirm(engine.records.last?.darts ?? [])
        engine.nextPlayer()
        camera?.pipeline.manualNext()
    }

    private func afterEdit(wasThrowing: Bool) {
        // Winnende pijl gecorrigeerd → leg loopt weer.
        if stage == .finished && engine.phase != .finished {
            stage = .playing
            statsRecorded = false
            camera?.pipeline.setMode(.game)
        }
        guard stage == .playing, let pipeline = camera?.pipeline, engine.phase == .throwing else { return }
        if wasThrowing {
            pipeline.setDartsCounted(engine.turn.count)
        } else {
            pipeline.resumeTurn(dartsInBoard: engine.turn.count)
        }
    }

    // MARK: - Bull-off

    var bullOffCurrent: GamePlayer? {
        guard bullOffState == .throwing, bullOffIndex < bullOffThrowers.count else { return nil }
        return bullOffThrowers[bullOffIndex]
    }

    private func registerBullOff(_ hit: DartHit) {
        guard let player = bullOffCurrent else { return }
        bullOffHits[player.id] = hit
        audio.announceDart(hit)
        bullOffIndex += 1
        if bullOffIndex >= bullOffThrowers.count { decideBullOff() }
    }

    private func bullOffPlayerAtBoard() {
        // Iemand loopt naar het bord terwijl nog niet iedereen gegooid heeft: rest = mis.
        guard bullOffState == .throwing, bullOffIndex > 0 else { return }
        while bullOffIndex < bullOffThrowers.count {
            bullOffHits[bullOffThrowers[bullOffIndex].id] = .miss
            bullOffIndex += 1
        }
        decideBullOff()
    }

    private func decideBullOff() {
        camera?.pipeline.lockTurn()
        let result = BullOff.decide(bullOffThrowers.map { (player: $0.id, hit: bullOffHits[$0.id]) })
        switch result {
        case .winner(let id):
            bullOffState = .decided(id)
            audio.announceFirstThrower(name(of: id))
        case .rethrow(let ids):
            bullOffState = .rethrow(ids)
            audio.say("Equal distance. Throw again.")
        }
    }

    private func bullOffBoardCleared() {
        switch bullOffState {
        case .decided(let id): startMatch(winner: id)
        case .rethrow(let ids): startRethrow(ids)
        case .throwing: break
        }
    }

    /// Opnieuw gooien (gelijkspel), enkel met de gelijke spelers.
    func startRethrow(_ ids: [UUID]) {
        bullOffThrowers = config.players.filter { ids.contains($0.id) }
        for id in ids { bullOffHits[id] = nil }
        bullOffIndex = 0
        bullOffState = .throwing
        camera?.pipeline.setMode(.bullOff)
    }

    /// Handmatig kiezen wie begint (zonder camera, of als de meting niet klopt).
    func chooseStarter(_ id: UUID) {
        if bullOffState != .decided(id) { audio.announceFirstThrower(name(of: id)) }
        startMatch(winner: id)
    }

    func startMatch(winner: UUID) {
        guard stage == .bullOff else { return }
        let ids = BullOff.order(config.players.map(\.id), startingWith: winner)
        order = ids.compactMap { id in config.players.first { $0.id == id } }
        engine = X01Engine(players: order.map { (id: $0.id, name: $0.name) },
                           startScore: config.startScore, doubleOut: config.doubleOut)
        wireEngine()
        stage = .playing
        camera?.pipeline.startGameMode()
    }

    // MARK: - Toast

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
