import Foundation

/// Slot a Bopomofo symbol occupies inside a syllable.
public enum BopomofoSlot: Int, Comparable {
    case initial = 0, medial = 1, final = 2

    public static func < (a: BopomofoSlot, b: BopomofoSlot) -> Bool { a.rawValue < b.rawValue }
}

public enum Tone: Int {
    case first = 1, second, third, fourth, neutral

    /// Mark appended to a reading. First tone is written without a mark.
    public var mark: String {
        switch self {
        case .first: return ""
        case .second: return "ˊ"
        case .third: return "ˇ"
        case .fourth: return "ˋ"
        case .neutral: return "˙"
        }
    }
}

/// Standard Taiwanese "大千" (Dachen) keyboard layout.
public enum DachenLayout {
    public static let symbols: [Character: Character] = [
        "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
        "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
        "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
        "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
        "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
        "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
        "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
        "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
        "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
        "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ", "-": "ㄦ",
    ]

    public static let tones: [Character: Tone] = [
        " ": .first, "6": .second, "3": .third, "4": .fourth, "7": .neutral,
    ]

    /// Every key that has a meaning in Zhuyin mode.
    public static func isZhuyinKey(_ c: Character) -> Bool {
        symbols[c] != nil || tones[c] != nil
    }

    static let initials: Set<Character> = Set("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ")
    static let medials: Set<Character> = Set("ㄧㄨㄩ")

    public static func slot(of symbol: Character) -> BopomofoSlot {
        if initials.contains(symbol) { return .initial }
        if medials.contains(symbol) { return .medial }
        return .final
    }
}

/// One syllable as composed from keystrokes.
public struct Syllable: Equatable {
    public var initial: Character?
    public var medial: Character?
    public var final: Character?
    public var tone: Tone?

    public init(initial: Character? = nil, medial: Character? = nil, final: Character? = nil, tone: Tone? = nil) {
        self.initial = initial
        self.medial = medial
        self.final = final
        self.tone = tone
    }

    public var isEmpty: Bool { initial == nil && medial == nil && final == nil }

    /// Bopomofo without tone, e.g. "ㄋㄧ".
    public var toneless: String {
        String([initial, medial, final].compactMap { $0 })
    }

    /// Reading with tone mark, e.g. "ㄋㄧˇ". Untoned syllables return just the symbols.
    public var reading: String { toneless + (tone?.mark ?? "") }

    public func filled(_ slot: BopomofoSlot) -> Bool {
        switch slot {
        case .initial: return initial != nil
        case .medial: return medial != nil
        case .final: return final != nil
        }
    }

    public mutating func set(_ symbol: Character, in slot: BopomofoSlot) {
        switch slot {
        case .initial: initial = symbol
        case .medial: medial = symbol
        case .final: final = symbol
        }
    }
}
