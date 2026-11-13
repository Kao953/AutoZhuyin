import XCTest
@testable import AutoZhuyinCore

private let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources")

private let sharedLexicon = try! Lexicon(contentsOf: resources.appendingPathComponent("lexicon.txt"))
private let windowsData = resources.deletingLastPathComponent().appendingPathComponent("windows/autozhuyin/data")
private let sharedEnglish = EnglishModel(commonWordsURL: resources.appendingPathComponent("english-common.txt"),
                                         dictionaryURL: windowsData.appendingPathComponent("english-dict.txt"),
                                         bigramURL: windowsData.appendingPathComponent("english-bigram.json"))
private let sharedWeights = Features.loadWeights(from: resources.appendingPathComponent("classifier-weights.json"))

final class ParserTests: XCTestCase {
    func testParsesNiHao() {
        let p = ZhuyinParser.parse(Array("su3cl3"))
        XCTAssertEqual(p.syllables.map(\.syllable.reading), ["ㄋㄧˇ", "ㄏㄠˇ"])
        XCTAssertNil(p.pending)
    }

    func testSpaceIsFirstTone() {
        let p = ZhuyinParser.parse(Array("wu0 "))
        XCTAssertEqual(p.syllables.map(\.syllable.reading), ["ㄊㄧㄢ"])
        XCTAssertEqual(p.syllables.first?.syllable.tone, .first)
    }

    func testPendingSyllable() {
        let p = ZhuyinParser.parse(Array("su3c"))
        XCTAssertEqual(p.completed.count, 1)
        XCTAssertEqual(p.pending?.syllable.reading, "ㄏ")
    }

    func testOutOfOrderSymbols() {
        // ㄧ ㄒ ㄠ ˇ → ㄒㄧㄠˇ (小); ㄒ ㄠ ㄧ ˇ → ㄒㄧㄠˇ
        for keys in ["uvl3", "vlu3", "ulv3"] {
            let p = ZhuyinParser.parse(Array(keys))
            XCTAssertEqual(p.syllables.map(\.syllable.reading), ["ㄒㄧㄠˇ"], keys)
            XCTAssertTrue(p.syllables[0].reordered, keys)
        }
        // In-order typing is unchanged and not flagged.
        XCTAssertFalse(ZhuyinParser.parse(Array("vul3")).syllables[0].reordered)
        // Symbols that no valid syllable combines (ㄩ then ㄍ) still start a new syllable.
        XCTAssertEqual(ZhuyinParser.parse(Array("me")).syllables.count, 2)
    }

    func testSyllableTable() {
        XCTAssertTrue(SyllableTable.valid.contains("ㄋㄧ"))
        XCTAssertTrue(SyllableTable.valid.contains("ㄓ"))
        XCTAssertFalse(SyllableTable.valid.contains("ㄐㄚ"))
        XCTAssertTrue(SyllableTable.validPrefixes.contains("ㄐㄧ"))
    }
}

final class ConverterTests: XCTestCase {
    func testConvertsPhrase() {
        let c = Converter(lexicon: sharedLexicon)
        let syl = ZhuyinParser.parse(Array("su3cl3")).syllables.map(\.syllable)
        XCTAssertEqual(c.convert(syl).map(\.text).joined(), "你好")
    }

    func testSentence() {
        let c = Converter(lexicon: sharedLexicon)
        let syl = ZhuyinParser.parse(Array("rup wu0 wu0 fu4cp3cl3")).syllables.map(\.syllable)
        XCTAssertEqual(c.convert(syl).map(\.text).joined(), "今天天氣很好")
    }

    func testLexiconLoadTime() throws {
        let start = Date()
        _ = try Lexicon(contentsOf: resources.appendingPathComponent("lexicon.txt"))
        let elapsed = Date().timeIntervalSince(start)
        print("lexicon load: \(elapsed)s")
        XCTAssertLessThan(elapsed, 3)
    }

    func testFixedCandidateWins() {
        let c = Converter(lexicon: sharedLexicon)
        let syl = ZhuyinParser.parse(Array("su3")).syllables.map(\.syllable)
        XCTAssertEqual(c.convert(syl, fixed: [0..<1: "妳"]).map(\.text).joined(), "妳")
    }

    func testToneOmissionStillConverts() {
        let c = Converter(lexicon: sharedLexicon)
        // ㄨㄛ (untoned) + ㄇㄣ˙ → 我們
        let syl = ZhuyinParser.parse(Array("jiap7")).syllables.map(\.syllable)
        XCTAssertEqual(c.convert(syl).map(\.text).joined(), "我們")
    }
}

final class ClassifierTests: XCTestCase {
    let classifier = Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights)

    func mode(_ s: String, finishing: Bool = false) -> InputMode {
        classifier.classify(Array(s), finishing: finishing).mode
    }

    func testZhuyin() {
        for s in ["su3cl3", "ji3", "cl3", "ru ", "u ", "fu ", "183", "2k7", "5j/ "] {
            XCTAssertEqual(mode(s), .zhuyin, s)
        }
        for s in ["ru", "ji", "fu"] { XCTAssertEqual(mode(s, finishing: true), .zhuyin, s) }
    }

    func testEnglish() {
        for s in ["hello", "the", "is", "ok", "github", "Swift", "2024", "so", "go", "me", "no", "a", "an", "up", "i", "meeting", "email", "push"] {
            XCTAssertEqual(mode(s, finishing: true), .literal, s)
        }
        XCTAssertEqual(mode("hello"), .literal)
    }

    func testLearningFlipsDecision() {
        let learned = LearnedPreferences()
        let c = Classifier(lexicon: sharedLexicon, english: sharedEnglish, learned: learned, weights: sharedWeights)
        XCTAssertEqual(c.classify(Array("so"), finishing: true).mode, .literal)
        learned.record("so", as: .zhuyin)
        XCTAssertEqual(c.classify(Array("so"), finishing: true).mode, .zhuyin)
    }
}

final class EngineTests: XCTestCase {
    func makeEngine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    /// Types a string and returns everything committed.
    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = c == "\n" ? .enter : c == "\t" ? .tab : .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    func testMixedSentence() {
        let e = makeEngine()
        // 我 + "hello world " + 你好
        XCTAssertEqual(type("ji3 hello world su3cl3 ", into: e), "我hello world 你好")
    }

    func testOutOfOrderTypingConverts() {
        let e = makeEngine()
        XCTAssertEqual(type("uvl3\n", into: e), "小")
        // A phrase typed with one syllable out of order converts like the in-order version.
        XCTAssertEqual(type("ulv3cl3\n", into: makeEngine()), type("vul3cl3\n", into: makeEngine()))
    }

    func testMarkedTextWhileTyping() {
        let e = makeEngine()
        _ = type("su3c", into: e)
        XCTAssertEqual(e.markedText, "你ㄏ")
        _ = type("l3", into: e)
        XCTAssertEqual(e.markedText, "你好")
    }

    func testEnterCommitsEnglish() {
        let e = makeEngine()
        XCTAssertEqual(type("github\n", into: e), "github")
    }

    func testTabTogglesAndLearns() {
        let e = makeEngine()
        _ = type("so", into: e)
        XCTAssertEqual(e.mode, .literal)
        _ = e.handle(.tab)
        XCTAssertEqual(e.mode, .zhuyin)
        _ = type("\n", into: e)
        XCTAssertEqual(e.classifier.learned.weights["so"], 1)
    }

    func testEnglishPunctuation() {
        let e = makeEngine()
        XCTAssertEqual(type("hello, ", into: e), "hello, ")
    }

    func testFullwidthPunctuationAfterChinese() {
        let e = makeEngine()
        XCTAssertEqual(type("su3cl3?", into: e), "你好？")
    }

    func testCandidates() {
        let e = makeEngine()
        _ = type("su3", into: e)
        _ = e.handle(.down)
        XCTAssertTrue(e.isShowingCandidates)
        let idx = e.candidates.firstIndex { $0.text == "妳" }!
        e.selectCandidate(idx)
        XCTAssertEqual(type("\n", into: e), "妳")
    }
}

final class DigitInitialTests: XCTestCase {
    func engine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func run(_ s: String) -> (out: String, marked: String) {
        let e = engine()
        var out = ""
        for c in s {
            let r = e.handle(c == "\n" ? .enter : .character(c))
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return (out, e.markedText)
    }

    func testDang3() {
        // 檔 = ㄉㄤˇ = "2;3": ";" (ㄤ) after a digit initial must not be treated as punctuation.
        let r = run("2;3")
        XCTAssertEqual(r.out, "")
        XCTAssertTrue(r.marked.hasPrefix("檔") || r.marked.hasPrefix("黨") || r.marked.hasPrefix("擋"), r.marked)
    }

    func testOtherDigitInitialSyllables() {
        XCTAssertEqual(run("2;3\n").out.count, 1)        // ㄉㄤˇ
        XCTAssertEqual(run("2j/ \n").out, "東")           // ㄉㄨㄥ
        XCTAssertEqual(run("1/4\n").out.count, 1)         // ㄅㄥˋ
    }

    func testNumbersStillWork() {
        XCTAssertEqual(run("2.5\n").out, "2.5")
        XCTAssertEqual(run("hello, ").out, "hello, ")
    }
}

final class MixedSegmentTests: XCTestCase {
    func run(_ s: String) -> (out: String, marked: String) {
        let e = CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
        var out = ""
        for c in s {
            let r = e.handle(c == "\n" ? .enter : .character(c))
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return (out, e.markedText)
    }

    func testChineseThenEnglish() {
        XCTAssertEqual(run("ji3hello ").out, "我hello ")
        XCTAssertEqual(run("su3cl3github\n").out, "你好github")
        XCTAssertEqual(run("ji3hel").marked, "我hel")
    }

    func testEnglishThenChinese() {
        XCTAssertEqual(run("hellosu3cl3 ").out, "hello你好")
        XCTAssertEqual(run("oksu3cl3\n").out, "ok你好")
    }

    func testThreeSegments() {
        XCTAssertEqual(run("ji3emailsu3cl3\n").out, "我email你好")
    }

    func testSingleLanguageUnchanged() {
        XCTAssertEqual(run("rup wu0 wu0 fu4cp3cl3\n").out, "今天天氣很好")
        XCTAssertEqual(run("helloworld\n").out, "helloworld")
        XCTAssertEqual(run("meeting ").out, "meeting ")
        XCTAssertEqual(run("183\n").out.count, 1)
    }
}

/// The Swift and Python cores must segment identically (fixtures from training/make_parity.py).
final class ParityTests: XCTestCase {
    func testMatchesPythonSegmentation() throws {
        let url = resources.deletingLastPathComponent().appendingPathComponent("training/parity-fixtures.json")
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        let c = Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights)
        var mismatches: [String] = []
        for fx in fixtures {
            let keys = Array(fx["keys"] as! String)
            let expected = (fx["segments"] as! [[Any]]).map { "\($0[0])-\($0[1]):\($0[2])" }
            let previous = (fx["previous"] as? String).flatMap(InputMode.init(rawValue:))
            let got = c.segment(keys, finishing: fx["finishing"] as! Bool, previous: previous).map {
                "\($0.range.lowerBound)-\($0.range.upperBound):\($0.mode.rawValue)"
            }
            if got != expected {
                mismatches.append("\(String(keys)) finishing=\(fx["finishing"]!) previous=\(String(describing: previous)): \(got) vs \(expected)")
            }
        }
        XCTAssertGreaterThan(fixtures.count, 300)
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches:\n" + mismatches.prefix(10).joined(separator: "\n"))
    }

    func testToneThenSpaceStaysChinese() {
        let e = CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
        var out = ""
        for c in "u4 " { if let t = e.handle(.character(c)).commit { out += t } }
        XCTAssertEqual(out.count, 1, out)
    }
}

final class ShiftTapTests: XCTestCase {
    func engine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = c == "⇧" ? .shiftTap : c == "\n" ? .enter : .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    func testShiftTapTogglesEnglishMode() {
        let e = engine()
        // "ru" alone would be ㄐㄧ (機); in English mode keys pass straight through, lowercase.
        XCTAssertEqual(type("⇧ru su ", into: e), "ru su ")
        XCTAssertTrue(e.isEnglishMode)                 // still English after spaces
        XCTAssertEqual(e.markedText, "")               // never composed: no underline
        XCTAssertEqual(type("\n", into: e), "\n")     // Enter goes to the app, mode stays
        XCTAssertTrue(e.isEnglishMode)
        XCTAssertEqual(type("⇧su3cl3\n", into: e), "你好")   // tap again: automatic again
        XCTAssertFalse(e.isEnglishMode)
    }

    func testShiftTapTwiceCancels() {
        XCTAssertEqual(type("⇧⇧su3cl3\n", into: engine()), "你好")
    }

    func testShiftTapMidWordFlips() {
        let e = engine()
        _ = type("so", into: e)
        XCTAssertEqual(e.mode, .literal)
        _ = e.handle(.shiftTap)
        XCTAssertEqual(e.mode, .zhuyin)
        XCTAssertFalse(e.isEnglishMode)                // a flip, not English mode
        _ = type("\n", into: e)
        XCTAssertEqual(e.classifier.learned.weights["so"], 1)   // a correction is learned
    }

    func testEnglishModeIsNotLearned() {
        let e = engine()
        _ = type("⇧hello ", into: e)
        XCTAssertTrue(e.classifier.learned.weights.isEmpty)
    }

    func testBackspaceInEnglishModeGoesToApp() {
        let e = engine()
        _ = type("⇧", into: e)
        XCTAssertFalse(e.handle(.backspace).handled)
        XCTAssertTrue(e.isEnglishMode)
    }

    func testDetector() {
        var d = ShiftTapDetector()
        XCTAssertFalse(d.modifiersChanged(shift: true, otherModifiers: false, time: 0))
        XCTAssertTrue(d.modifiersChanged(shift: false, otherModifiers: false, time: 0.1))
        // Shift used for a capital letter: not a tap.
        _ = d.modifiersChanged(shift: true, otherModifiers: false, time: 1)
        d.keyPressed()
        XCTAssertFalse(d.modifiersChanged(shift: false, otherModifiers: false, time: 1.1))
        // Held too long: not a tap.
        _ = d.modifiersChanged(shift: true, otherModifiers: false, time: 2)
        XCTAssertFalse(d.modifiersChanged(shift: false, otherModifiers: false, time: 3))
        // Shift + Command: not a tap.
        _ = d.modifiersChanged(shift: true, otherModifiers: false, time: 4)
        _ = d.modifiersChanged(shift: true, otherModifiers: true, time: 4.1)
        XCTAssertFalse(d.modifiersChanged(shift: false, otherModifiers: false, time: 4.2))
    }
}

final class CursorTests: XCTestCase {
    func engine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = c == "←" ? .left : c == "→" ? .right : c == "↓" ? .down : c == "\n" ? .enter
                : c == "\u{8}" ? .backspace : .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    func testCursorMovesAndClamps() {
        let e = engine()
        _ = type("rup wu0 wu0 fu4", into: e)        // 今天天氣
        XCTAssertEqual(e.cursorOffset, 4)
        _ = type("←", into: e)
        XCTAssertEqual(e.cursorOffset, 3)
        _ = type("←←←←", into: e)
        XCTAssertEqual(e.cursorOffset, 0)              // stops at the start
        _ = type("→→→→", into: e)
        XCTAssertEqual(e.cursorOffset, 4)
    }

    func testChooseCandidateInTheMiddle() {
        let e = engine()
        _ = type("rup wu0 wu0 fu4", into: e)
        _ = type("←←↓", into: e)                       // cursor after the 2nd syllable (天)
        XCTAssertTrue(e.isShowingCandidates)
        XCTAssertTrue(e.candidates.allSatisfy { $0.range.upperBound == 2 })
        let i = e.candidates.firstIndex { $0.text == "添" }!
        e.selectCandidate(i)
        XCTAssertEqual(type("\n", into: e), "今添天氣")
    }

    func testPunctuationCommitsFromTheMiddle() {
        let e = engine()
        _ = type("rup wu0 ←", into: e)
        XCTAssertEqual(e.cursorOffset, 1)
        _ = type("?", into: e)
        XCTAssertEqual(e.markedText, "")
    }

    func testInsertSyllable() {
        let e = engine()
        _ = type("rup fu4←wu", into: e)
        XCTAssertEqual(e.markedText, "今ㄊㄧ氣")
        XCTAssertEqual(e.cursorOffset, 3)
        _ = type("0 ", into: e)
        XCTAssertEqual(e.markedText, "今天氣")
        XCTAssertEqual(e.cursorOffset, 2)
        XCTAssertEqual(type("\n", into: e), "今天氣")
    }

    func testInsertAtStart() {
        XCTAssertEqual(type("su3cl3←←ji3\n", into: engine()), "我你好")
    }

    func testBackspaceDeletesCharacterBeforeCursor() {
        let e = engine()
        _ = type("rup wu0 wu0 fu4←←\u{8}", into: e)
        XCTAssertEqual(e.markedText, "今天氣")
        XCTAssertEqual(e.cursorOffset, 1)
    }

    func testBackspaceInsideInsertedSyllable() {
        let e = engine()
        _ = type("rup fu4←wu\u{8}", into: e)
        XCTAssertEqual(e.markedText, "今ㄊ氣")
    }

    func testKeepsPickedPhraseBeforeCursor() {
        let e = engine()
        _ = type("rup wu0 ↓", into: e)
        e.selectCandidate(e.candidates.firstIndex { $0.text == "添" }!)
        _ = type("fu4←wu0 ", into: e)                  // insert 天 between 添 and 氣
        XCTAssertEqual(String(e.markedText.prefix(3)), "今添天")
    }

    func testCandidatesForChineseBeforeEnglish() {
        let e = engine()
        _ = type("su3cl3hello", into: e)               // 你好hello
        _ = type("↓", into: e)                         // last Chinese syllable, not the English word
        XCTAssertTrue(e.isShowingCandidates)
    }
}

final class FirstToneAfterEnglishTests: XCTestCase {
    /// After an English word, a first-tone syllable + space must stay Chinese (機, 吃, 書…).
    func testFirstToneAfterEnglish() {
        for keys in ["ru", "t", "gj", "vup", "tj", "el"] {
            let e = CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
            var out = ""
            for c in "hello " + keys + " " { if let t = e.handle(.character(c)).commit { out += t } }
            out += e.handle(.enter).commit ?? ""
            XCTAssertEqual(String(out.prefix(6)), "hello ", keys)
            XCTAssertEqual(out.count, 7, keys)                 // one Chinese character after it
            XCTAssertFalse(out.last!.isASCII, keys)
        }
    }
}

final class HeldWordTests: XCTestCase {
    func makeEngine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = c == "\n" ? .enter : .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    /// "up " is also ㄧㄣ (因): the next word decides.
    func testNextWordDecides() {
        let cases = ["up jo4 ": "因為", "up the ": "up the ", "pick up the ": "pick up the ",
                     "up\n": "up", "i love ": "i love "]
        for (keys, want) in cases {
            XCTAssertEqual(type(keys, into: makeEngine()), want, keys)
        }
    }

    func testHeldWordStaysComposing() {
        let e = makeEngine()
        XCTAssertEqual(type("up ", into: e), "")
        XCTAssertEqual(e.markedText, "up ")
        _ = e.handle(.backspace)
        XCTAssertEqual(e.markedText, "up")
        XCTAssertEqual(type(" the ", into: e), "up the ")
    }
}

final class BacktickSymbolTests: XCTestCase {
    func makeEngine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = c == "\n" ? .enter : .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    func testForcedSymbols() {
        let cases = ["`<": "，", "`.": "。", "`?": "？", "`;": "；", "`[": "「",
                     "hello`,": "hello，", "su3cl3`.": "你好。", "```\n": "```"]
        for (keys, want) in cases {
            XCTAssertEqual(type(keys, into: makeEngine()), want, keys)
        }
    }

    func testPlainBacktick() {
        let e = makeEngine()
        XCTAssertEqual(type("`", into: e), "")
        XCTAssertEqual(e.markedText, "`")
        XCTAssertEqual(type("ls` ", into: e), "`ls` ")
    }

    func testBackspaceCancels() {
        let e = makeEngine()
        _ = type("su3`", into: e)
        _ = e.handle(.backspace)
        XCTAssertEqual(e.markedText, "你")
    }
}

final class FirstWordHoldTests: XCTestCase {
    func makeEngine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let r = e.handle(c == "\n" ? .enter : .character(c))
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    /// The first word is not committed as English on space if it also reads as Zhuyin.
    func testNextWordDecides() {
        let cases = ["el ji3 ": "高我", "no su3cl3 ": "no 你好", "ok ji3 ": "ok 我",
                     "i love you ": "i love you ", "up the ": "up the "]
        for (keys, want) in cases {
            XCTAssertEqual(type(keys, into: makeEngine()), want, keys)
        }
    }

    func testNotHeldAfterEnglish() {
        let e = makeEngine()
        XCTAssertEqual(type("hello world ", into: e), "hello world ")
        XCTAssertEqual(type("so ", into: e), "so ")   // right after English: commits at once
    }
}

final class StartupTimingTests: XCTestCase {
    func testStartupTiming() throws {
        var t = Date()
        func lap(_ name: String) { print(String(format: "STARTUP %@: %.3fs", name, Date().timeIntervalSince(t))); t = Date() }
        _ = try Lexicon(contentsOf: resources.appendingPathComponent("lexicon.txt")); lap("lexicon")
        _ = EnglishModel(commonWordsURL: resources.appendingPathComponent("english-common.txt"),
                         dictionaryURL: windowsData.appendingPathComponent("english-dict.txt"),
                         bigramURL: windowsData.appendingPathComponent("english-bigram.json")); lap("english")
        _ = Features.loadWeights(from: resources.appendingPathComponent("classifier-weights.json")); lap("weights")
    }
}
