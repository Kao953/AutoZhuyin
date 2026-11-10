import Foundation

/// The inventory of valid (toneless) Mandarin syllables in Bopomofo.
public enum SyllableTable {
    private static let raw = """
    ㄚ ㄛ ㄜ ㄝ ㄞ ㄟ ㄠ ㄡ ㄢ ㄣ ㄤ ㄥ ㄦ
    ㄧ ㄧㄚ ㄧㄛ ㄧㄝ ㄧㄞ ㄧㄠ ㄧㄡ ㄧㄢ ㄧㄣ ㄧㄤ ㄧㄥ
    ㄨ ㄨㄚ ㄨㄛ ㄨㄞ ㄨㄟ ㄨㄢ ㄨㄣ ㄨㄤ ㄨㄥ
    ㄩ ㄩㄝ ㄩㄢ ㄩㄣ ㄩㄥ
    ㄅㄚ ㄅㄛ ㄅㄞ ㄅㄟ ㄅㄠ ㄅㄢ ㄅㄣ ㄅㄤ ㄅㄥ ㄅㄧ ㄅㄧㄝ ㄅㄧㄠ ㄅㄧㄢ ㄅㄧㄣ ㄅㄧㄥ ㄅㄨ
    ㄆㄚ ㄆㄛ ㄆㄞ ㄆㄟ ㄆㄠ ㄆㄡ ㄆㄢ ㄆㄣ ㄆㄤ ㄆㄥ ㄆㄧ ㄆㄧㄝ ㄆㄧㄠ ㄆㄧㄢ ㄆㄧㄣ ㄆㄧㄥ ㄆㄨ
    ㄇㄚ ㄇㄛ ㄇㄜ ㄇㄞ ㄇㄟ ㄇㄠ ㄇㄡ ㄇㄢ ㄇㄣ ㄇㄤ ㄇㄥ ㄇㄧ ㄇㄧㄝ ㄇㄧㄠ ㄇㄧㄡ ㄇㄧㄢ ㄇㄧㄣ ㄇㄧㄥ ㄇㄨ
    ㄈㄚ ㄈㄛ ㄈㄟ ㄈㄡ ㄈㄢ ㄈㄣ ㄈㄤ ㄈㄥ ㄈㄨ
    ㄉㄚ ㄉㄜ ㄉㄞ ㄉㄟ ㄉㄠ ㄉㄡ ㄉㄢ ㄉㄣ ㄉㄤ ㄉㄥ ㄉㄧ ㄉㄧㄚ ㄉㄧㄝ ㄉㄧㄠ ㄉㄧㄡ ㄉㄧㄢ ㄉㄧㄥ ㄉㄨ ㄉㄨㄛ ㄉㄨㄟ ㄉㄨㄢ ㄉㄨㄣ ㄉㄨㄥ
    ㄊㄚ ㄊㄜ ㄊㄞ ㄊㄠ ㄊㄡ ㄊㄢ ㄊㄤ ㄊㄥ ㄊㄧ ㄊㄧㄝ ㄊㄧㄠ ㄊㄧㄢ ㄊㄧㄥ ㄊㄨ ㄊㄨㄛ ㄊㄨㄟ ㄊㄨㄢ ㄊㄨㄣ ㄊㄨㄥ
    ㄋㄚ ㄋㄜ ㄋㄞ ㄋㄟ ㄋㄠ ㄋㄡ ㄋㄢ ㄋㄣ ㄋㄤ ㄋㄥ ㄋㄧ ㄋㄧㄝ ㄋㄧㄠ ㄋㄧㄡ ㄋㄧㄢ ㄋㄧㄣ ㄋㄧㄤ ㄋㄧㄥ ㄋㄨ ㄋㄨㄛ ㄋㄨㄢ ㄋㄨㄥ ㄋㄩ ㄋㄩㄝ
    ㄌㄚ ㄌㄛ ㄌㄜ ㄌㄞ ㄌㄟ ㄌㄠ ㄌㄡ ㄌㄢ ㄌㄤ ㄌㄥ ㄌㄧ ㄌㄧㄚ ㄌㄧㄝ ㄌㄧㄠ ㄌㄧㄡ ㄌㄧㄢ ㄌㄧㄣ ㄌㄧㄤ ㄌㄧㄥ ㄌㄨ ㄌㄨㄛ ㄌㄨㄢ ㄌㄨㄣ ㄌㄨㄥ ㄌㄩ ㄌㄩㄝ ㄌㄩㄢ
    ㄍㄚ ㄍㄜ ㄍㄞ ㄍㄟ ㄍㄠ ㄍㄡ ㄍㄢ ㄍㄣ ㄍㄤ ㄍㄥ ㄍㄨ ㄍㄨㄚ ㄍㄨㄛ ㄍㄨㄞ ㄍㄨㄟ ㄍㄨㄢ ㄍㄨㄣ ㄍㄨㄤ ㄍㄨㄥ
    ㄎㄚ ㄎㄜ ㄎㄞ ㄎㄟ ㄎㄠ ㄎㄡ ㄎㄢ ㄎㄣ ㄎㄤ ㄎㄥ ㄎㄨ ㄎㄨㄚ ㄎㄨㄛ ㄎㄨㄞ ㄎㄨㄟ ㄎㄨㄢ ㄎㄨㄣ ㄎㄨㄤ ㄎㄨㄥ
    ㄏㄚ ㄏㄜ ㄏㄞ ㄏㄟ ㄏㄠ ㄏㄡ ㄏㄢ ㄏㄣ ㄏㄤ ㄏㄥ ㄏㄨ ㄏㄨㄚ ㄏㄨㄛ ㄏㄨㄞ ㄏㄨㄟ ㄏㄨㄢ ㄏㄨㄣ ㄏㄨㄤ ㄏㄨㄥ
    ㄐㄧ ㄐㄧㄚ ㄐㄧㄝ ㄐㄧㄠ ㄐㄧㄡ ㄐㄧㄢ ㄐㄧㄣ ㄐㄧㄤ ㄐㄧㄥ ㄐㄩ ㄐㄩㄝ ㄐㄩㄢ ㄐㄩㄣ ㄐㄩㄥ
    ㄑㄧ ㄑㄧㄚ ㄑㄧㄝ ㄑㄧㄠ ㄑㄧㄡ ㄑㄧㄢ ㄑㄧㄣ ㄑㄧㄤ ㄑㄧㄥ ㄑㄩ ㄑㄩㄝ ㄑㄩㄢ ㄑㄩㄣ ㄑㄩㄥ
    ㄒㄧ ㄒㄧㄚ ㄒㄧㄝ ㄒㄧㄠ ㄒㄧㄡ ㄒㄧㄢ ㄒㄧㄣ ㄒㄧㄤ ㄒㄧㄥ ㄒㄩ ㄒㄩㄝ ㄒㄩㄢ ㄒㄩㄣ ㄒㄩㄥ
    ㄓ ㄓㄚ ㄓㄜ ㄓㄞ ㄓㄟ ㄓㄠ ㄓㄡ ㄓㄢ ㄓㄣ ㄓㄤ ㄓㄥ ㄓㄨ ㄓㄨㄚ ㄓㄨㄛ ㄓㄨㄞ ㄓㄨㄟ ㄓㄨㄢ ㄓㄨㄣ ㄓㄨㄤ ㄓㄨㄥ
    ㄔ ㄔㄚ ㄔㄜ ㄔㄞ ㄔㄠ ㄔㄡ ㄔㄢ ㄔㄣ ㄔㄤ ㄔㄥ ㄔㄨ ㄔㄨㄚ ㄔㄨㄛ ㄔㄨㄞ ㄔㄨㄟ ㄔㄨㄢ ㄔㄨㄣ ㄔㄨㄤ ㄔㄨㄥ
    ㄕ ㄕㄚ ㄕㄜ ㄕㄞ ㄕㄟ ㄕㄠ ㄕㄡ ㄕㄢ ㄕㄣ ㄕㄤ ㄕㄥ ㄕㄨ ㄕㄨㄚ ㄕㄨㄛ ㄕㄨㄞ ㄕㄨㄟ ㄕㄨㄢ ㄕㄨㄣ ㄕㄨㄤ
    ㄖ ㄖㄜ ㄖㄠ ㄖㄡ ㄖㄢ ㄖㄣ ㄖㄤ ㄖㄥ ㄖㄨ ㄖㄨㄛ ㄖㄨㄟ ㄖㄨㄢ ㄖㄨㄣ ㄖㄨㄥ
    ㄗ ㄗㄚ ㄗㄜ ㄗㄞ ㄗㄟ ㄗㄠ ㄗㄡ ㄗㄢ ㄗㄣ ㄗㄤ ㄗㄥ ㄗㄨ ㄗㄨㄛ ㄗㄨㄟ ㄗㄨㄢ ㄗㄨㄣ ㄗㄨㄥ
    ㄘ ㄘㄚ ㄘㄜ ㄘㄞ ㄘㄠ ㄘㄡ ㄘㄢ ㄘㄣ ㄘㄤ ㄘㄥ ㄘㄨ ㄘㄨㄛ ㄘㄨㄟ ㄘㄨㄢ ㄘㄨㄣ ㄘㄨㄥ
    ㄙ ㄙㄚ ㄙㄜ ㄙㄞ ㄙㄠ ㄙㄡ ㄙㄢ ㄙㄣ ㄙㄤ ㄙㄥ ㄙㄨ ㄙㄨㄛ ㄙㄨㄟ ㄙㄨㄢ ㄙㄨㄣ ㄙㄨㄥ
    """

    public static let valid: Set<String> = Set(raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Every prefix (in initial→medial→final order) of a valid syllable, e.g. "ㄋ", "ㄋㄧ".
    public static let validPrefixes: Set<String> = {
        var s = Set<String>()
        for syl in valid {
            let chars = Array(syl)
            for n in 1...chars.count { s.insert(String(chars[0..<n])) }
        }
        return s
    }()

    /// Every valid syllable with any of its slots blanked out, as "initial|medial|final"
    /// with "_" for an empty slot (e.g. "ㄒ_ㄠ" from ㄒㄧㄠ). Used to accept symbols typed
    /// out of order: a partial syllable is fine if some valid syllable completes it.
    private static let compatiblePatterns: Set<String> = {
        var s = Set<String>()
        for syl in valid {
            var slots: [Character?] = [nil, nil, nil]
            for c in syl { slots[DachenLayout.slot(of: c).rawValue] = c }
            for mask in 0..<8 {
                let masked = (0..<3).map { i -> Character in
                    mask & (1 << i) != 0 ? (slots[i] ?? "_") : "_"
                }
                s.insert(String(masked))
            }
        }
        return s
    }()

    public static func isCompatible(_ syllable: Syllable) -> Bool {
        compatiblePatterns.contains(String([syllable.initial ?? "_", syllable.medial ?? "_", syllable.final ?? "_"]))
    }

    public static func isValid(_ syllable: Syllable) -> Bool { valid.contains(syllable.toneless) }
    public static func isValidPrefix(_ syllable: Syllable) -> Bool {
        syllable.isEmpty || validPrefixes.contains(syllable.toneless)
    }
}
