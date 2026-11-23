import Foundation

/// A syllable parsed out of a key sequence, with the key range that produced it.
public struct ParsedSyllable: Equatable {
    public var syllable: Syllable
    public var keyRange: Range<Int>
    /// True when its symbols were typed out of initial→medial→final order.
    public var reordered = false
    /// True when the syllable was closed by a tone key.
    public var toned: Bool { syllable.tone != nil }
}

public struct ZhuyinParse: Equatable {
    public var syllables: [ParsedSyllable]
    /// Number of tone keys that had no syllable to attach to (e.g. "33").
    public var strayTones: Int
    /// Keys that are not part of the Dachen layout at all (uppercase, `'`, …).
    public var foreignKeys: Int

    /// The trailing syllable that is still being composed (not closed by a tone), if any.
    public var pending: ParsedSyllable? {
        guard let last = syllables.last, !last.toned else { return nil }
        return last
    }

    /// Syllables that are finished: either toned, or untoned but followed by another syllable.
    public var completed: [ParsedSyllable] {
        pending == nil ? syllables : Array(syllables.dropLast())
    }
}

/// Splits raw keystrokes into syllables following Dachen composition rules:
/// symbols fill initial → medial → final; a symbol whose slot (or a later one)
/// is already filled starts a new syllable; a tone key closes the syllable.
public enum ZhuyinParser {
    /// `strict`: every syllable gets its tone (要打聲調才出字), so symbols typed over an untoned
    /// syllable are a correction even when they read alone (ㄒㄧㄥ then ㄩˊ is ㄒㄩㄥˊ).
    public static func parse(_ keys: [Character], strict: Bool = false) -> ZhuyinParse {
        var result = ZhuyinParse(syllables: [], strayTones: 0, foreignKeys: 0)
        var current = Syllable()
        var start = 0
        var reordered = false

        func close(at end: Int) {
            if !current.isEmpty {
                result.syllables.append(ParsedSyllable(syllable: current, keyRange: start..<end, reordered: reordered))
            }
            current = Syllable()
            start = end
            reordered = false
        }

        for (i, key) in keys.enumerated() {
            if let tone = DachenLayout.tones[key] {
                if current.isEmpty {
                    result.strayTones += 1
                    start = i + 1
                } else {
                    if let prev = result.syllables.last, prev.keyRange.upperBound == start, !prev.toned,
                       strict || !SyllableTable.isValid(current) {
                        // Typed over the untoned syllable before it to fix a typo: ㄌㄨㄥ then ㄏ
                        // and a tone is ㄏㄨㄥ, not ㄌㄨㄥ + ㄏ (which is no syllable).
                        var merged = prev.syllable
                        if let s = current.initial { merged.initial = s }
                        if let s = current.medial { merged.medial = s }
                        if let s = current.final { merged.final = s }
                        if SyllableTable.isValid(merged) {
                            result.syllables.removeLast()
                            current = merged
                            start = prev.keyRange.lowerBound
                            reordered = true
                        }
                    }
                    current.tone = tone
                    close(at: i + 1)
                }
            } else if let symbol = DachenLayout.symbols[key] {
                let slot = DachenLayout.slot(of: symbol)
                let laterFilled = [BopomofoSlot.initial, .medial, .final].contains { $0 > slot && current.filled($0) }
                if current.filled(slot) {
                    close(at: i)
                } else if laterFilled {
                    // Typed out of order (e.g. ㄧ then ㄒ for ㄒㄧ). Merge into the current
                    // syllable when some valid syllable fits; otherwise start a new one.
                    var merged = current
                    merged.set(symbol, in: slot)
                    if SyllableTable.isCompatible(merged) {
                        reordered = true
                    } else {
                        close(at: i)
                    }
                }
                if current.isEmpty { start = i }
                current.set(symbol, in: slot)
            } else {
                close(at: i)
                result.foreignKeys += 1
                start = i + 1
            }
        }
        close(at: keys.count)
        return result
    }
}
