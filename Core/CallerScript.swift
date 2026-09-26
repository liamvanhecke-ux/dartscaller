import Foundation

/// Hoe de caller klinkt.
enum CallerStyle: String, CaseIterable, Identifiable, Codable {
    /// Uitgerekt en dramatisch zoals op TV ("One hundred and eightyyy!"), met naam bij "you require".
    case tv = "TV-caller"
    /// Neutraal en vlot.
    case standard = "Standaard"
    var id: String { rawValue }
}

/// Eén uit te spreken zin: SSML voor iOS 16+, platte tekst als terugval.
struct CallerLine: Equatable {
    let ssml: String
    let plain: String
    /// Pauze vóór de zin (seconden).
    let delay: Double
    /// Voor de platte terugval.
    let pitch: Float
    let rate: Float
}

/// Zet spelgebeurtenissen om naar wat de caller zegt. Platformonafhankelijk en getest.
enum CallerScript {

    // MARK: Per pijl

    static func dart(_ hit: DartHit, multiplierWord: String, style: CallerStyle) -> CallerLine {
        let text: String
        switch (hit.segment, hit.multiplier) {
        case (_, 0):     text = "Miss"
        case (25, 2):    text = "Bullseye"
        case (25, 1):    text = "Outer Bull"
        case (let s, 3): text = "\(multiplierWord) \(s)"
        case (let s, 2): text = "Double \(s)"
        case (let s, _): text = "Single \(s)"
        }
        switch style {
        case .standard:
            return line(text, plain: text)
        case .tv:
            // Kort en zakelijk: het echte drama komt bij het totaal.
            return line(prosody(escape(text), rate: "95%", pitch: "-2%"), plain: text, rate: 0.5)
        }
    }

    // MARK: Na de beurt

    /// - Parameters:
    ///   - name: speler die net gooide (voor "Liam, you require 40"), nil = zonder naam.
    static func turn(total: Int, outcome: TurnOutcome, won: Bool, remaining: Int, name: String?,
                     requireThreshold: Int = 150, style: CallerStyle) -> [CallerLine] {
        var lines: [CallerLine] = []

        if won {
            lines.append(style == .tv
                ? line(prosody("Game shot", rate: "80%", pitch: "+10%", volume: "x-loud") +
                       #"<break time="250ms"/>"# +
                       prosody("and the match!", rate: "75%", pitch: "+15%", volume: "x-loud"),
                       plain: "Game shot, and the match!", delay: 0.35, pitch: 1.1)
                : line("Game shot, and the match!", plain: "Game shot, and the match!", delay: 0.35, pitch: 1.1))
            return lines
        }

        switch outcome {
        case .checkout:
            lines.append(line(style == .tv ? prosody("Game shot!", rate: "80%", pitch: "+10%", volume: "x-loud") : "Game shot!",
                              plain: "Game shot!", delay: 0.35, pitch: 1.1))
            return lines
        case .bust:
            lines.append(line(style == .tv ? prosody("No score.", rate: "85%", pitch: "-6%") : "No score.",
                              plain: "No score", delay: 0.35))
        case .scored:
            lines.append(scoreLine(total, style: style))
        }

        if remaining <= requireThreshold && remaining >= 2 {
            let words = NumberWords.british(remaining)
            let who = name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            switch style {
            case .standard:
                lines.append(line("You require \(words)", plain: "You require \(words)", delay: 0.45))
            case .tv:
                var ssml = ""
                if let who { ssml += escape(who) + #",<break time="150ms"/> "# }
                ssml += prosody("you require", rate: "90%") + #"<break time="120ms"/>"# + prosody(words, rate: "80%", pitch: "+4%")
                let plain = (who.map { "\($0), you" } ?? "You") + " require \(words)"
                lines.append(line(ssml, plain: plain, delay: 0.5))
            }
        }
        return lines
    }

    static func scoreLine(_ total: Int, style: CallerStyle) -> CallerLine {
        let words = NumberWords.british(total)
        if total == 0 {
            return line(style == .tv ? prosody("No score.", rate: "85%", pitch: "-6%") : "No score.",
                        plain: "No score", delay: 0.35)
        }
        guard style == .tv else {
            return line(words, plain: words, delay: 0.35, pitch: total >= 100 ? 1.08 : 1.0)
        }
        if total == 180 {
            // "One hundred and… eightyyy!"
            let ssml = prosody("One hundred and", rate: "80%", pitch: "+8%", volume: "x-loud") +
                       #"<break time="120ms"/>"# +
                       prosody("eighty!", rate: "40%", pitch: "+22%", volume: "x-loud")
            return line(ssml, plain: "One hundred and eighty!", delay: 0.35, pitch: 1.15, rate: 0.42)
        }
        if total >= 100 {
            // Ton-plus: laatste woord uitrekken en hoger
            let rest = total - 100
            let ssml = rest == 0
                ? prosody("One hundred!", rate: "65%", pitch: "+12%", volume: "loud")
                : prosody("One hundred and", rate: "85%", pitch: "+5%", volume: "loud") + " " +
                  prosody(NumberWords.british(rest) + "!", rate: "60%", pitch: "+14%", volume: "loud")
            return line(ssml, plain: words + "!", delay: 0.35, pitch: 1.08)
        }
        if total >= 60 {
            return line(prosody(words + "!", rate: "72%", pitch: "+8%", volume: "loud"), plain: words, delay: 0.35, pitch: 1.04)
        }
        return line(prosody(words, rate: "85%"), plain: words, delay: 0.35)
    }

    static func firstThrower(_ name: String, style: CallerStyle) -> CallerLine {
        let plain = "\(name) to throw first. Game on!"
        guard style == .tv else { return line(escape(plain), plain: plain, delay: 0.2) }
        let ssml = escape(name) + " to throw first." + #"<break time="350ms"/>"# +
                   prosody("Game on!", rate: "70%", pitch: "+12%", volume: "x-loud")
        return line(ssml, plain: plain, delay: 0.2)
    }

    static func correction(style: CallerStyle) -> CallerLine {
        line(style == .tv ? prosody("Correction.", rate: "90%", pitch: "-4%") : "Correction.", plain: "Correction.")
    }

    // MARK: SSML-hulp

    private static func line(_ body: String, plain: String, delay: Double = 0, pitch: Float = 1.0, rate: Float = 0.48) -> CallerLine {
        CallerLine(ssml: "<speak>\(body)</speak>", plain: plain, delay: delay, pitch: pitch, rate: rate)
    }

    private static func prosody(_ inner: String, rate: String? = nil, pitch: String? = nil, volume: String? = nil) -> String {
        var attrs = ""
        if let rate { attrs += " rate=\"\(rate)\"" }
        if let pitch { attrs += " pitch=\"\(pitch)\"" }
        if let volume { attrs += " volume=\"\(volume)\"" }
        return "<prosody\(attrs)>\(inner)</prosody>"
    }

    /// Spelersnamen kunnen &, < of > bevatten.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
