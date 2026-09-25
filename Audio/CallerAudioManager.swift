import AVFoundation
import Observation

/// "Match Referee": spreekt elke pijl, het beurttotaal en de resterende score (≤ 150) uit in het Engels.
@Observable
@MainActor
final class CallerAudioManager {

    enum MultiplierWord: String, CaseIterable, Identifiable {
        case triple = "Triple"
        case treble = "Treble"   // zo zeggen echte callers het
        var id: String { rawValue }
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "caller.enabled"); if !isEnabled { stop() } }
    }
    var multiplierWord: MultiplierWord {
        didSet { UserDefaults.standard.set(multiplierWord.rawValue, forKey: "caller.multiplierWord") }
    }
    /// Vanaf deze resterende score (en lager) volgt "You require X".
    let requireThreshold = 150

    private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?

    init() {
        let d = UserDefaults.standard
        isEnabled = d.object(forKey: "caller.enabled") as? Bool ?? true
        multiplierWord = MultiplierWord(rawValue: d.string(forKey: "caller.multiplierWord") ?? "") ?? .triple
        voice = Self.bestEnglishVoice()
        let session = AVAudioSession.sharedInstance()
        // .playback: ook hoorbaar met de stille-modus-schakelaar aan. Andere audio wordt zachter gezet.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Beste beschikbare Britse stem (Premium > Enhanced > standaard), anders Amerikaans.
    /// Premium-stemmen downloadt de gebruiker via Instellingen › Toegankelijkheid › Gesproken materiaal › Stemmen.
    static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        for lang in ["en-GB", "en-US"] {
            let v = all.filter { $0.language == lang }
            if let best = v.first(where: { $0.quality == .premium }) ?? v.first(where: { $0.quality == .enhanced }) {
                return best
            }
        }
        return AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static var hasHighQualityVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && ($0.quality == .premium || $0.quality == .enhanced)
        }
    }

    // MARK: - Publieke API

    /// 1. Na elke afzonderlijke pijl: "Triple 20", "Single 1", "Miss", "Outer Bull", "Bullseye".
    func announceDart(_ hit: DartHit) {
        speak(phrase(for: hit))
    }

    /// 2 + 3. Na de beurt: totaal ("180!", "60", "26"), daarna "You require X" als X ≤ 150.
    func announceTurn(_ record: TurnRecord, won: Bool) {
        if won {
            speak("Game shot, and the match!", delay: 0.35, pitch: 1.1)
            return
        }
        switch record.outcome {
        case .bust:
            speak("No score", delay: 0.35)
        case .checkout:
            speak("Game shot!", delay: 0.35, pitch: 1.1)
            return
        case .scored:
            let total = record.countedPoints
            if total == 180 {
                speak("One hundred and eighty!", delay: 0.35, pitch: 1.15, rate: 0.42)
            } else if total == 0 {
                speak("No score", delay: 0.35)
            } else {
                speak(Self.numberWords(total), delay: 0.35, pitch: total >= 100 ? 1.08 : 1.0)
            }
        }
        let remaining = record.endRemaining
        if remaining <= requireThreshold && remaining >= 2 {
            speak("You require \(Self.numberWords(remaining))", delay: 0.45)
        }
    }

    func announceCorrection(_ record: TurnRecord) {
        speak("Correction.", rate: 0.5)
        announceTurn(record, won: record.outcome == .checkout)
    }

    func announceFirstThrower(_ name: String) {
        speak("\(name) to throw first. Game on!", delay: 0.2)
    }

    func say(_ text: String) { speak(text) }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// Opnieuw de beste stem zoeken (na het downloaden van een Premium-stem).
    func refreshVoice() { voice = Self.bestEnglishVoice() }

    var voiceDescription: String {
        guard let v = voice else { return "Standaard" }
        let q: String
        switch v.quality {
        case .premium: q = "Premium"
        case .enhanced: q = "Verbeterd"
        default: q = "Standaard"
        }
        return "\(v.name) (\(v.language), \(q))"
    }

    // MARK: - Tekst

    func phrase(for hit: DartHit) -> String {
        switch (hit.segment, hit.multiplier) {
        case (_, 0):     return "Miss"
        case (25, 2):    return "Bullseye"
        case (25, 1):    return "Outer Bull"
        case (let s, 3): return "\(multiplierWord.rawValue) \(s)"
        case (let s, 2): return "Double \(s)"
        case (let s, _): return "Single \(s)"
        }
    }

    static func numberWords(_ n: Int) -> String { NumberWords.british(n) }

    // MARK: - Intern

    /// AVSpeechSynthesizer zet utterances zelf in een wachtrij: pijl 3 + totaal + "You require" volgen netjes op elkaar.
    private func speak(_ text: String, delay: TimeInterval = 0, pitch: Float = 1.0, rate: Float = 0.48) {
        guard isEnabled else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.pitchMultiplier = pitch
        u.preUtteranceDelay = delay
        synth.speak(u)
    }
}
