import XCTest
@testable import AutoZhuyinCore

private let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources")

private let sharedLexicon = try! Lexicon(contentsOf: resources.appendingPathComponent("lexicon.txt"))
private let sharedEnglish = EnglishModel(commonWordsURL: resources.appendingPathComponent("english-common.txt"))

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
    let classifier = Classifier(lexicon: sharedLexicon, english: sharedEnglish)

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
        let c = Classifier(lexicon: sharedLexicon, english: sharedEnglish, learned: learned)
        XCTAssertEqual(c.classify(Array("so"), finishing: true).mode, .literal)
        learned.record("so", as: .zhuyin)
        XCTAssertEqual(c.classify(Array("so"), finishing: true).mode, .zhuyin)
    }
}

final class EngineTests: XCTestCase {
    func makeEngine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish))
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
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish))
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
        let e = CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish))
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
