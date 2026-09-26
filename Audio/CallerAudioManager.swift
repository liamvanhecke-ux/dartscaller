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
    var style: CallerStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "caller.style") }
    }
    /// Spreektempo van de caller (1.0 = standaard). Instelbaar met een schuif.
    var tempo: Double {
        didSet { UserDefaults.standard.set(tempo, forKey: "caller.tempo") }
    }
    /// Zelf gekozen stem (identifier), nil = automatisch de beste.
    var chosenVoiceID: String? {
        didSet {
            UserDefaults.standard.set(chosenVoiceID, forKey: "caller.voice")
            refreshVoice()
        }
    }
    /// Vanaf deze resterende score (en lager) volgt "You require X".
    let requireThreshold = 150

    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?

    init() {
        let d = UserDefaults.standard
        isEnabled = d.object(forKey: "caller.enabled") as? Bool ?? true
        multiplierWord = MultiplierWord(rawValue: d.string(forKey: "caller.multiplierWord") ?? "") ?? .treble
        style = CallerStyle(rawValue: d.string(forKey: "caller.style") ?? "") ?? .tv
        tempo = d.object(forKey: "caller.tempo") as? Double ?? 1.0
        chosenVoiceID = d.string(forKey: "caller.voice")
        voice = Self.voice(for: d.string(forKey: "caller.voice"))
        let session = AVAudioSession.sharedInstance()
        // .playback: ook hoorbaar met de stille-modus-schakelaar aan. Andere audio wordt zachter gezet.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Beste stem voor een darts-caller: Britse mannenstem, Premium > Verbeterd > standaard.
    /// Premium-stemmen downloadt de gebruiker via Instellingen › Toegankelijkheid › Gesproken materiaal › Stemmen.
    static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium: s += 100
            case .enhanced: s += 50
            default: break
            }
            if v.language == "en-GB" { s += 20 }            // Britse caller
            if v.gender == .male { s += 10 }
            if v.identifier.contains("eloquence") || v.identifier.contains("speech.synthesis.voice") { s -= 200 } // novelty/robot-stemmen
            return s
        }
        return english.max { score($0) < score($1) }
            ?? AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        return bestEnglishVoice()
    }

    /// Alle Engelse stemmen op dit toestel, beste eerst (voor de keuzelijst in Instellingen).
    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.identifier.contains("eloquence") && !$0.identifier.contains("speech.synthesis.voice") }
            .sorted { ($0.quality.rawValue, $0.language == "en-GB" ? 1 : 0, $0.name) > ($1.quality.rawValue, $1.language == "en-GB" ? 1 : 0, $1.name) }
    }

    static var hasHighQualityVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && ($0.quality == .premium || $0.quality == .enhanced)
        }
    }

    // MARK: - Publieke API

    /// 1. Na elke afzonderlijke pijl: "Treble 20", "Single 1", "Miss", "Outer Bull", "Bullseye".
    func announceDart(_ hit: DartHit) {
        speak(CallerScript.dart(hit, multiplierWord: multiplierWord.rawValue, style: style, tempo: tempo))
    }

    /// 2 + 3. Na de beurt: totaal ("One hundred and eighty!", "sixty"), daarna "Liam, you require forty" als ≤ 150.
    func announceTurn(_ record: TurnRecord, won: Bool, name: String? = nil) {
        for line in CallerScript.turn(total: record.countedPoints, outcome: record.outcome, won: won,
                                      remaining: record.endRemaining, name: name,
                                      requireThreshold: requireThreshold, style: style, tempo: tempo) {
            speak(line)
        }
    }

    func announceCorrection(_ record: TurnRecord, name: String? = nil) {
        speak(CallerScript.correction(style: style, tempo: tempo))
        announceTurn(record, won: record.outcome == .checkout, name: name)
    }

    func announceFirstThrower(_ name: String) {
        speak(CallerScript.firstThrower(name, style: style, tempo: tempo))
    }

    /// Voorbeeld voor in Instellingen.
    func demo() {
        stop()
        speak(CallerScript.dart(.triple(20), multiplierWord: multiplierWord.rawValue, style: style, tempo: tempo))
        speak(CallerScript.dart(.triple(20), multiplierWord: multiplierWord.rawValue, style: style, tempo: tempo))
        speak(CallerScript.dart(.triple(20), multiplierWord: multiplierWord.rawValue, style: style, tempo: tempo))
        for line in CallerScript.turn(total: 180, outcome: .scored, won: false, remaining: 141, name: "Liam", style: style, tempo: tempo) {
            speak(line)
        }
        for line in CallerScript.turn(total: 60, outcome: .scored, won: false, remaining: 81, name: "Liam", style: style, tempo: tempo) {
            speak(line)
        }
    }

    func say(_ text: String) {
        let plain = CallerLine(ssml: "<speak>\(CallerScript.escape(text))</speak>", plain: text, delay: 0, pitch: 1, rate: 0.48)
        speak(plain)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// Opnieuw de beste stem zoeken (na het downloaden van een Premium-stem).
    func refreshVoice() { voice = Self.voice(for: chosenVoiceID) }

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

    /// AVSpeechSynthesizer zet utterances zelf in een wachtrij: pijl 3 + totaal + "you require" volgen netjes op elkaar.
    private func speak(_ line: CallerLine) {
        guard isEnabled else { return }
        let utterance: AVSpeechUtterance
        if let ssml = AVSpeechUtterance(ssmlRepresentation: line.ssml) {
            utterance = ssml                       // tempo/toonhoogte/pauzes per woord (TV-caller)
        } else {
            utterance = AVSpeechUtterance(string: line.plain)   // terugval: hele zin in één toon
            utterance.rate = line.rate
            utterance.pitchMultiplier = line.pitch
        }
        utterance.voice = voice
        utterance.preUtteranceDelay = line.delay
        synth.speak(utterance)
    }
}
