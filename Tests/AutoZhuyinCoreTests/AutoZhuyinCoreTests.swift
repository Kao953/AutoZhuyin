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

    /// An initial typed again before the tone replaces the one before: ㄌㄨㄥ ㄏ ˊ = ㄏㄨㄥˊ.
    func testTypedOver() {
        func readings(_ keys: String) -> [String] { ZhuyinParser.parse(Array(keys)).syllables.map(\.syllable.reading) }
        XCTAssertEqual(readings("xj/c "), ["ㄏㄨㄥ"])
        XCTAssertEqual(readings("su3xj/c6"), ["ㄋㄧˇ", "ㄏㄨㄥˊ"])
        XCTAssertTrue(ZhuyinParser.parse(Array("xj/c ")).syllables[0].reordered)
        // Only when the symbol alone is no syllable: these stay as they were.
        XCTAssertEqual(readings("xj/cj3"), ["ㄌㄨㄥ", "ㄏㄨˇ"])
        XCTAssertEqual(readings("5kg4"), ["ㄓㄜ", "ㄕˋ"])     // 這是, first tone omitted
        XCTAssertEqual(readings("xj/ c "), ["ㄌㄨㄥ", "ㄏ"])   // the first one had its tone
        XCTAssertEqual(readings("xj/v "), ["ㄌㄨㄥ", "ㄒ"])     // ㄒㄨㄥ is no syllable either
    }

    /// 要打聲調才出字: every syllable has its tone, so anything typed over an untoned one corrects it.
    func testStrictTypedOver() {
        func strict(_ keys: String) -> [String] { ZhuyinParser.parse(Array(keys), strict: true).syllables.map(\.syllable.reading) }
        XCTAssertEqual(strict("vu/m6"), ["ㄒㄩㄥˊ"])               // ㄒㄧㄥ, ㄩ over ㄧ
        XCTAssertEqual(ZhuyinParser.parse(Array("vu/m6")).syllables.map(\.syllable.reading), ["ㄒㄧㄥ", "ㄩˊ"])   // not strict
        XCTAssertEqual(strict("cj/; "), ["ㄏㄨㄤ"])                // ㄏㄨㄥ, ㄤ over ㄥ
        XCTAssertEqual(strict("xj/cj/3"), ["ㄏㄨㄥˇ"])             // the whole syllable typed again
        XCTAssertEqual(strict("j04u "), ["ㄨㄢˋ", "ㄧ"])            // 萬一 with its tones
        XCTAssertEqual(strict("xj/v "), ["ㄌㄨㄥ", "ㄒ"])            // ㄒㄨㄥ is no syllable: kept apart

        func type(_ keys: String, strict: Bool) -> String {
            let e = CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
            e.requireTones = strict
            var out = ""
            for c in keys {
                let r = e.handle(c == "\n" ? .enter : .character(c))
                if let t = r.commit { out += t } else if !r.handled { out.append(c) }
            }
            return out
        }
        XCTAssertEqual(type("vu/m6\n", strict: true), "雄")
        XCTAssertEqual(type("su3vu/m6\n", strict: true), "你雄")
        XCTAssertEqual(type("j04u \n", strict: true), "萬一")
        XCTAssertEqual(type("vu/m6\n", strict: false).count, 2)   // not strict: two characters, as before
        XCTAssertEqual(type("su3cpu3\n", strict: true), "你ㄏㄣ以")   // untoned stays Bopomofo (ㄏㄧㄣ is no syllable)
        XCTAssertEqual(type("su3cpcl3\n", strict: true), "你好")      // ㄏㄣ typed over with ㄏㄠˇ
        XCTAssertEqual(type("su3cpcl3\n", strict: false), "你很好")
    }

    /// The Bopomofo itself comes last among the candidates.
    func testBopomofoCandidates() {
        let syl = ZhuyinParser.parse(Array(";6")).syllables.map(\.syllable)
        let texts = Converter(lexicon: sharedLexicon).candidates(syl, endingAt: 1).map(\.text)
        XCTAssertEqual(Array(texts.suffix(2)), ["ㄤ", "ㄤˊ"])
        let first = ZhuyinParser.parse(Array("/ ")).syllables.map(\.syllable)
        XCTAssertEqual(Converter(lexicon: sharedLexicon).candidates(first, endingAt: 1).filter { $0.text == "ㄥ" }.count, 1)
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

    /// Tab flips only the last segment; what is before it stays, and only that word is learned.
    func testTabFlipsTheLastSegment() {
        let e = makeEngine()
        _ = type("ji3so\t", into: e)
        XCTAssertEqual(e.segments.map(\.range), [0..<3, 3..<5])
        XCTAssertTrue(e.markedText.hasPrefix("我"))
        XCTAssertEqual(type("\n", into: e), "我內")
        XCTAssertEqual(e.classifier.learned.weights, ["so": 1])
        XCTAssertEqual(type("ji3so\t\t\n", into: makeEngine()), "我so")   // Tab again flips it back
        // In Chinese, the last character: 我要 Tab is 我ul4; Tab again gives 我要 back.
        XCTAssertEqual(type("ji3ul4\t\n", into: makeEngine()), "我ul4")
        XCTAssertEqual(type("ji3ul4\t\t\n", into: makeEngine()), "我要")
        XCTAssertEqual(type("su3cl3\t\n", into: makeEngine()), "你cl3")
        // Backspace after a flip, then commit: the learned word is what is left of it.
        let f = makeEngine()
        _ = type("so\t", into: f)
        _ = f.handle(.backspace)
        XCTAssertEqual(f.handle(.enter).commit?.count, 1)
    }

    /// The menu-bar input mode can switch English mode directly.
    func testSetEnglishMode() {
        let e = makeEngine()
        e.setEnglishMode(true)
        XCTAssertTrue(e.isEnglishMode)
        XCTAssertEqual(e.handle(.character("a")).handled, false)   // goes to the app
        e.setEnglishMode(false)
        XCTAssertEqual(type("su3cl3 ", into: e), "你好")
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
        XCTAssertEqual(type("xj/c \n", into: makeEngine()), "轟")   // ㄌㄨㄥ fixed by typing ㄏ over it
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

    /// Tab right after a commit retypes it in the other mode and learns the correction.
    func testFlipLastCommit() {
        let e = makeEngine()
        XCTAssertEqual(type("so ", into: e), "so ")
        XCTAssertEqual(e.flippableText, "so ")
        let zh = e.flipLastCommit()
        XCTAssertNotNil(zh)
        XCTAssertFalse(zh!.contains("s"))
        XCTAssertEqual(e.classifier.learned.weights["so"], 1)
        // Tab again flips it back.
        XCTAssertEqual(e.flippableText, zh)
        XCTAssertEqual(e.flipLastCommit(), "so ")

        XCTAssertEqual(type("su3cl3 ", into: e), "你好")
        XCTAssertEqual(e.flipLastCommit(), "su3cl3 ")
        XCTAssertEqual(type("ji  ", into: e).count, 1)     // first tone, then space commits
        XCTAssertEqual(e.flipLastCommit(), "ji ")          // the tone space isn't kept

        // Not after Enter: Tab next is completion ("cd shell" ⏎ Tab in a terminal).
        XCTAssertEqual(type("shell\n", into: e), "shell")
        XCTAssertNil(e.flippableText)
    }

    /// Only right after the commit, and only for keys that can be reread.
    func testFlipLastCommitLimits() {
        let e = makeEngine()
        _ = type("hello a", into: e)
        XCTAssertNil(e.flippableText)                       // typing goes on
        _ = e.commitAll()
        _ = type("Hello ", into: e)
        XCTAssertNil(e.flippableText)                       // capitals aren't Dachen keys
        _ = type("so ", into: e)
        _ = e.handle(.left)                                 // any key forgets it
        XCTAssertNil(e.flippableText)
        XCTAssertEqual(e.handle(.tab), .passThrough)
        _ = type("so ", into: e)
        _ = e.handleControl(".")
        XCTAssertNil(e.flippableText)
    }

    func testEnglishPunctuation() {
        let e = makeEngine()
        XCTAssertEqual(type("hello, ", into: e), "hello, ")
    }

    func testThreeDotsAreAnEllipsis() {
        XCTAssertEqual(type("ji3...", into: makeEngine()), "我…")
        XCTAssertEqual(type("su3cl3......", into: makeEngine()), "你好……")
        XCTAssertEqual(type("hello...", into: makeEngine()), "hello...")
    }

    func testFullwidthPunctuationAfterChinese() {
        let e = makeEngine()
        XCTAssertEqual(type("su3cl3?\n", into: e), "你好？")
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
        XCTAssertEqual(e.cursorOffset, 1)              // stops after the first character
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
        XCTAssertEqual(e.markedText, "今天？")
        XCTAssertEqual(e.cursorOffset, 3)
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

    func testCursorStopsAfterFirstCharacter() {
        let e = engine()
        _ = type("su3cl3←←←", into: e)
        XCTAssertEqual(e.cursorOffset, 1)
    }

    func testBackspaceDeletesCharacterBeforeCursor() {
        let e = engine()
        _ = type("rup wu0 wu0 fu4←←\u{8}", into: e)
        XCTAssertEqual(e.markedText, "今天氣")
        XCTAssertEqual(e.cursorOffset, 1)
    }

    func testBackspaceAtEndDeletesWholeCharacter() {
        let e = engine()
        _ = type("rup wu0 \u{8}", into: e)
        XCTAssertEqual(e.markedText, "今")             // 天 goes at once, not just its tone
        _ = type("wu\u{8}", into: e)
        XCTAssertEqual(e.markedText, "今ㄊ")            // Bopomofo still being typed: one key
        _ = type("\u{8}\u{8}", into: e)
        XCTAssertEqual(e.markedText, "")
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
            let key: KeyInput = c == "\n" ? .enter : c == "\t" ? .tab : .character(c)
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

    /// After Chinese only common one-syllable words are held ("up" = 因/音); "push" isn't.
    func testNextWordDecidesAfterChinese() {
        let cases = ["5k4ek7up m,4 ": "這個音樂", "5k4ek7up jo4 ": "這個因為", "5k4ek7up the ": "這個up the ",
                     "5k4ek7up\n": "這個up", "ji3ul4push ": "我要push "]
        for (keys, want) in cases {
            XCTAssertEqual(type(keys, into: makeEngine()), want, keys)
        }
        let e = makeEngine()
        XCTAssertEqual(type("5k4ek7up ", into: e), "")
        XCTAssertEqual(e.markedText, "這個up ")
    }

    func testHeldWordStaysComposing() {
        let e = makeEngine()
        XCTAssertEqual(type("up ", into: e), "")
        XCTAssertEqual(e.markedText, "up ")
        _ = e.handle(.backspace)
        XCTAssertEqual(e.markedText, "up")
        XCTAssertEqual(type(" the ", into: e), "up the ")
    }

    /// Words with digits / punctuation keys are held too: "0 " is 安, "5j; " is 裝.
    func testHeldWordWithDigitKeys() {
        let learned = LearnedPreferences(weights: ["0": -2])   // "0" once learned as a number
        let c = Classifier(lexicon: sharedLexicon, english: sharedEnglish, learned: learned, weights: sharedWeights)
        XCTAssertEqual(type("0 5j; \n", into: CompositionEngine(classifier: c)), "安裝")
        XCTAssertEqual(type("0 \n", into: CompositionEngine(classifier: c)), "0 ")
    }

    /// One Tab undoes a wrong learned preference, and only the word flipped is learned.
    func testTabOverridesLearned() {
        let learned = LearnedPreferences(weights: ["0": -2])
        let c = Classifier(lexicon: sharedLexicon, english: sharedEnglish, learned: learned, weights: sharedWeights)
        XCTAssertEqual(type("0\t 5j; \n", into: CompositionEngine(classifier: c)), "安裝")
        XCTAssertEqual(learned.weights["0"], 1)
        XCTAssertNil(learned.weights["0 5j; "])
        XCTAssertEqual(type("hello 0 5j; \n", into: CompositionEngine(classifier: c)), "hello 安裝")
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

    func testBackslashIsDunhao() {
        XCTAssertEqual(type("ji3\\\n", into: makeEngine()), "我、")
        XCTAssertEqual(type("hello\\", into: makeEngine()), "hello\\")
    }

    func testControlSymbols() {
        let e = makeEngine()
        _ = type("ji3", into: e)
        XCTAssertEqual(e.handleControl(";"), KeyResult(handled: true, commit: "我；"))
        XCTAssertEqual(e.handleControl("'"), KeyResult(handled: true, commit: "、"))
        XCTAssertNil(e.handleControl("c"))
    }

    func testSymbolTable() {
        let e = makeEngine()
        XCTAssertEqual(type("ji3` ", into: e), "我")
        XCTAssertTrue(e.isSymbolTable)
        XCTAssertEqual(type("4", into: e), "；")
        _ = e.handle(.character("`"))
        _ = e.handle(.down)
        _ = e.handle(.down)
        XCTAssertEqual(e.handle(.enter).commit, "。")
        _ = type("` ", into: e)
        XCTAssertEqual(e.selectCandidate(2), "、")   // mouse click
        _ = type("` ", into: e)
        _ = e.handle(.escape)
        XCTAssertFalse(e.isShowingCandidates)
        XCTAssertEqual(type("su3 ", into: e), "你")
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

/// A Shift-punctuation typed with nothing composed waits for the next key; Tab switches it.
final class HeldPunctuationTests: XCTestCase {
    func makeEngine() -> CompositionEngine {
        CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = ["\n": .enter, "\t": .tab, "⇧": .shiftTap, "\u{8}": .backspace, "↓": .down][c] ?? .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    func testTabSwitches() {
        let e = makeEngine()
        XCTAssertEqual(type("<", into: e), "")
        XCTAssertEqual(e.markedText, "<")
        XCTAssertEqual(e.cursorOffset, 1)
        _ = type("\t", into: e)
        XCTAssertEqual(e.markedText, "，")
        _ = type("⇧", into: e)
        XCTAssertEqual(e.markedText, "<")
        XCTAssertFalse(e.isEnglishMode)
        XCTAssertEqual(type("\tsu3", into: e), "，")
        XCTAssertEqual(e.markedText, "你")
    }

    func testGuessFromContext() {
        XCTAssertEqual(type("ji3 <\n", into: makeEngine()), "我，")
        XCTAssertEqual(type("ji3 !\t\n", into: makeEngine()), "我!")
        XCTAssertEqual(type("ji3<\n", into: makeEngine()), "我，")
        XCTAssertEqual(type("hello!", into: makeEngine()), "hello!")   // after English: sent at once
        XCTAssertEqual(type("hello\\", into: makeEngine()), "hello\\")
    }

    func testSpaceSendsIt() {
        XCTAssertEqual(type("! ", into: makeEngine()), "! ")
        XCTAssertEqual(type("ji3 ! ", into: makeEngine()), "我！")
    }

    /// The switch says which language is being typed: the next punctuation follows it.
    func testSwitchIsRemembered() {
        XCTAssertEqual(type("<\t>\n", into: makeEngine()), "，。")
    }

    func testBackspaceCancels() {
        let e = makeEngine()
        XCTAssertEqual(type("(\u{8}", into: e), "")
        XCTAssertEqual(e.markedText, "")
    }

    /// After Chinese it waits too, after the composition; the next key sends both.
    func testHeldAfterChinese() {
        let e = makeEngine()
        XCTAssertEqual(type("ji3[", into: e), "")
        XCTAssertEqual(e.markedText, "我「")
        XCTAssertEqual(type("su3", into: e), "我「")
        XCTAssertEqual(e.markedText, "你")
        XCTAssertEqual(type("ji3<\t\n", into: makeEngine()), "我<")
        XCTAssertEqual(type("ji3(\u{8}\n", into: makeEngine()), "我")
    }

    /// Enter sends the punctuation like a composition, without a new line.
    func testEnterSendsItOnly() {
        let e = makeEngine()
        _ = type("!", into: e)
        XCTAssertEqual(e.handle(.enter), KeyResult(handled: true, commit: "!"))
    }

    func testDownPicksAnother() {
        let e = makeEngine()
        _ = type("ji3[↓", into: e)
        XCTAssertTrue(e.isPunctuationTable)
        let texts = e.candidates.map(\.text)
        XCTAssertEqual(Array(texts.prefix(4)), ["「", "『", "（", "【"])
        XCTAssertEqual(texts[e.candidateIndex], "「")
        _ = type("2", into: e)
        XCTAssertFalse(e.isShowingCandidates)
        XCTAssertEqual(e.markedText, "我『")   // picked, not sent yet
        XCTAssertEqual(type("\n", into: e), "我『")
    }

    func testChoices() {
        XCTAssertEqual(CompositionEngine.punctuationChoices("{").first, "『")
        XCTAssertEqual(CompositionEngine.punctuationChoices("{").last, "{")
        XCTAssertEqual(Set(CompositionEngine.punctuationChoices("(")).count, CompositionEngine.punctuationChoices("(").count)
        XCTAssertEqual(Array(CompositionEngine.punctuationChoices(")").prefix(2)), ["）", "」"])
        XCTAssertTrue(CompositionEngine.punctuationChoices("<").contains("、"))
    }

    func testTabAfterAPick() {
        let e = makeEngine()
        _ = type("ji3 (↓", into: e)
        e.selectCandidate(e.candidates.firstIndex { $0.text == "【" }!)
        XCTAssertEqual(e.markedText, "【")
        _ = type("\t", into: e)
        XCTAssertEqual(e.markedText, "(")
        _ = type("\t", into: e)
        XCTAssertEqual(e.markedText, "（")
    }

    func testCommitAll() {
        let e = makeEngine()
        _ = type("ji3 ?", into: e)
        XCTAssertEqual(e.commitAll(), "？")
        _ = type("?", into: e)
        XCTAssertEqual(e.handleControl(","), KeyResult(handled: true, commit: "？，"))
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

final class UserHistoryTests: XCTestCase {
    var saved: [UserHistory.Data] = []
    var classifier: Classifier!

    override func setUp() {
        saved = []
        classifier = Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights,
                                history: UserHistory { [unowned self] in self.saved.append($0) })
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let key: KeyInput = c == "↓" ? .down : c == "\n" ? .enter : .character(c)
            let r = e.handle(key)
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    @discardableResult
    func pick(_ keys: String, _ phrase: String) -> String {
        let e = CompositionEngine(classifier: classifier)
        _ = type(keys + "↓", into: e)
        e.selectCandidate(e.candidates.firstIndex { $0.text == phrase }!)
        return type("\n", into: e)
    }

    func testPickedCandidateComesFirst() {
        XCTAssertEqual(type("wu0 \n", into: CompositionEngine(classifier: classifier)), "天")
        XCTAssertEqual(pick("wu0 ", "添"), "添")
        XCTAssertEqual(type("wu0 \n", into: CompositionEngine(classifier: classifier)), "添")
        let e = CompositionEngine(classifier: classifier)
        _ = type("wu0 ↓", into: e)
        XCTAssertEqual(e.candidates.first?.text, "添")
        XCTAssertEqual(saved.last, ["ㄊㄧㄢ": ["添": [1, 1]]])
    }

    func testPhrasesStillWin() {
        pick("wu0 ", "添")
        XCTAssertEqual(type("rup wu0 \n", into: CompositionEngine(classifier: classifier)), "今天")
    }

    func testMostPickedWins() {
        pick("wu0 ", "添")
        pick("wu0 ", "添")
        pick("wu0 ", "天")
        XCTAssertEqual(type("wu0 \n", into: CompositionEngine(classifier: classifier)), "添")
    }

    func testRoundTripAndClear() throws {
        pick("wu0 ", "添")
        let json = try JSONEncoder().encode(saved.last!)
        let h = UserHistory(data: try JSONDecoder().decode(UserHistory.Data.self, from: json))
        XCTAssertEqual(h.data, ["ㄊㄧㄢ": ["添": [1, 1]]])
        h.record(ZhuyinParser.parse(Array("wu0 ")).syllables.map(\.syllable), phrase: "天")
        XCTAssertEqual(h.data["ㄊㄧㄢ"]?["天"], [1, 2])
        h.clear()
        XCTAssertTrue(h.data.isEmpty)
    }

    func testEvictsLeastRecent() {
        let h = UserHistory()
        h.maxEntries = 2
        let syl = ZhuyinParser.parse(Array("wu0 ")).syllables.map(\.syllable)
        for p in ["天", "添", "田"] { h.record(syl, phrase: p) }
        XCTAssertEqual(Set(h.data["ㄊㄧㄢ"]!.keys), ["添", "田"])
    }
}

/// Needs build/lm/lm.bin (scripts/fetch-lm.sh); skipped otherwise.
final class GPT2LanguageModelTests: XCTestCase {
    static let dir = resources.deletingLastPathComponent().appendingPathComponent("build/lm")

    func model() throws -> GPT2LanguageModel {
        let bin = GPT2LanguageModelTests.dir.appendingPathComponent("lm.bin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bin.path), "run scripts/fetch-lm.sh")
        return try GPT2LanguageModel(modelURL: bin, vocabURL: GPT2LanguageModelTests.dir.appendingPathComponent("lm-vocab.txt"))
    }

    /// Same numbers as the numpy reference (training/lm/gpt2.py, float32 weights).
    func testMatchesReference() throws {
        let m = try model()
        let cases: [(String, String, Double)] = [("他在家", "", -14.329), ("今天天氣很好", "", -30.08),
                                                 ("今添天氣很好", "", -44.392), ("家", "他在", -5.514),
                                                 ("天氣很好", "今天", -23.883)]
        for (text, context, want) in cases {
            XCTAssertEqual(m.logProb(text, context: context), want, accuracy: 0.05, text)
        }
    }

    /// Characters outside the model's vocabulary don't win just because [UNK] is likely.
    func testUnknownCharacterIsUnlikely() throws {
        let m = try model()
        XCTAssertGreaterThan(m.logProb("好耶", context: ""), m.logProb("好䱒", context: ""))
    }

    func testSpeed() throws {
        let m = try model()
        let start = Date()
        for _ in 0..<20 { _ = m.logProb("我們明天早上八點在車站見面", context: "好啊") }
        let ms = Date().timeIntervalSince(start) / 20 * 1000
        print("GPT2 logProb: \(String(format: "%.2f", ms)) ms")
        XCTAssertLessThan(ms, 20)
    }
}

/// A language model that likes one string and can pretend to be slow.
private final class FakeLanguageModel: LanguageModel {
    var liked: String
    var onCall: () -> Void = {}
    init(liked: String) { self.liked = liked }
    func logProb(_ text: String, context: String) -> Double {
        onCall()
        return text.contains(liked) ? 0 : -50
    }
}

final class RerankerTests: XCTestCase {
    func engine(_ reranker: Reranker?) -> CompositionEngine {
        let e = CompositionEngine(classifier: Classifier(lexicon: sharedLexicon, english: sharedEnglish, weights: sharedWeights))
        e.reranker = reranker
        return e
    }

    func type(_ s: String, into e: CompositionEngine) -> String {
        var out = ""
        for c in s {
            let r = e.handle(c == "\n" ? .enter : .character(c))
            if let t = r.commit { out += t } else if !r.handled { out.append(c) }
        }
        return out
    }

    func testRerankPicksWhatTheModelLikes() {
        XCTAssertEqual(type("wu0 \n", into: engine(nil)), "天")
        let r = Reranker(mode: .standard, model: FakeLanguageModel(liked: "添"))
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "添")
        XCTAssertEqual(r.status, .active)
    }

    func testOffAndLoadingUseTheLexicon() {
        let off = Reranker(mode: .off, model: FakeLanguageModel(liked: "添"))
        XCTAssertEqual(type("wu0 \n", into: engine(off)), "天")
        XCTAssertEqual(off.status, .off)
        let loading = Reranker(mode: .standard, model: nil)
        XCTAssertEqual(type("wu0 \n", into: engine(loading)), "天")
        XCTAssertEqual(loading.status, .loading)
    }

    func testPausedWhenSystemBusy() {
        let r = Reranker(mode: .standard, model: FakeLanguageModel(liked: "添"))
        r.systemState = { .paused }
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "天")
        XCTAssertEqual(r.status, .pausedBusy)
    }

    func testReducedUsesFewerPaths() {
        let lm = FakeLanguageModel(liked: "添")
        var calls = 0
        lm.onCall = { calls += 1 }
        let r = Reranker(mode: .quality, model: lm)
        r.systemState = { .reduced }
        _ = type("wu0 \n", into: engine(r))
        XCTAssertLessThanOrEqual(calls, 3)
    }

    func marked(_ e: CompositionEngine) -> String { e.markedPieces.map(\.text).joined() }

    func testLargeModelIsUsedWhenCommitting() {
        let r = Reranker(mode: .quality, model: FakeLanguageModel(liked: "天"))
        r.largeModel = FakeLanguageModel(liked: "添")
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "添")
    }

    func testLargeModelRunsInTheBackground() {
        let r = Reranker(mode: .quality, model: FakeLanguageModel(liked: "天"))
        let large = FakeLanguageModel(liked: "添")
        let gate = DispatchSemaphore(value: 0)
        large.onCall = { gate.wait() }
        r.largeModel = large
        let updated = expectation(description: "onUpdate")
        r.onUpdate = { updated.fulfill() }
        let e = engine(r)
        _ = type("wu0 ", into: e)
        XCTAssertEqual(marked(e), "天")              // the small model's result meanwhile
        for _ in 0..<Reranker.largeK { gate.signal() }
        wait(for: [updated], timeout: 5)
        XCTAssertEqual(marked(e), "添")
    }

    func testCommitDoesNotWaitLongForTheLargeModel() {
        let r = Reranker(mode: .quality, model: FakeLanguageModel(liked: "天"))
        let large = FakeLanguageModel(liked: "添")
        let gate = DispatchSemaphore(value: 0)
        large.onCall = { gate.wait() }
        r.largeModel = large
        let start = Date()
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "天")
        XCTAssertLessThan(Date().timeIntervalSince(start), CompositionEngine.commitWait + 0.5)
        for _ in 0..<Reranker.largeK { gate.signal() }
    }

    func testQualityWithoutTheLargeModelIsStandard() {
        let r = Reranker(mode: .quality, model: FakeLanguageModel(liked: "添"))
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "添")
    }

    func testSlowModelIsDroppedThenPaused() {
        var clock = Date(timeIntervalSince1970: 0)
        let lm = FakeLanguageModel(liked: "添")
        lm.onCall = { clock.addTimeInterval(1) }        // every call takes a "second"
        let r = Reranker(mode: .standard, model: lm)
        r.now = { clock }
        for _ in 0..<3 { XCTAssertEqual(type("wu0 \n", into: engine(r)), "天") }
        XCTAssertEqual(r.status, .pausedSlow)
        lm.onCall = {}
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "天")   // still paused
        clock.addTimeInterval(61)
        XCTAssertEqual(type("wu0 \n", into: engine(r)), "添")   // back after a minute
    }

    /// With the real model (build/lm, skipped if missing): sentences the lexicon alone gets wrong.
    func testRealModelFixesHomophones() throws {
        let dir = GPT2LanguageModelTests.dir
        let bin = dir.appendingPathComponent("lm.bin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bin.path), "run scripts/fetch-lm.sh")
        let lm = try GPT2LanguageModel(modelURL: bin, vocabURL: dir.appendingPathComponent("lm-vocab.txt"))
        let cases = ["w8 ql32k71u3ji3dj94cp32ji ": "他跑得比我快很多",
                     "fu/3su3y94gji u h4cl3a87": "請你再說一次好嗎"]
        for (keys, want) in cases {
            XCTAssertNotEqual(type(keys + "\n", into: engine(nil)), want)
            XCTAssertEqual(type(keys + "\n", into: engine(Reranker(mode: .standard, model: lm))), want)
        }
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

final class UserPhrasesTests: XCTestCase {
    func testRoundTripKeepsComments() {
        let text = "# 我的詞\nㄗˋ-ㄉㄨㄥˋ 自動 -1\n\n注音 ㄓㄨˋ-ㄧㄣ\n"
        var u = UserPhrases(text: text)
        XCTAssertEqual(u.entries.map(\.phrase), ["自動", "注音"])
        XCTAssertNil(u.entries[1].score)
        XCTAssertEqual(u.text, "# 我的詞\nㄗˋ-ㄉㄨㄥˋ 自動 -1\n\nㄓㄨˋ-ㄧㄣ 注音\n")
        u.remove(at: 0)
        u.append(UserPhrases.Entry(phrase: "妳好", reading: "ㄋㄧˇ-ㄏㄠˇ"))
        XCTAssertEqual(u.text, "# 我的詞\n\nㄓㄨˋ-ㄧㄣ 注音\nㄋㄧˇ-ㄏㄠˇ 妳好 -1\n")
        u.replace(at: 0, with: UserPhrases.Entry(phrase: "註音", reading: "ㄓㄨˋ-ㄧㄣ", score: -2.5))
        XCTAssertEqual(u.entries[0], UserPhrases.Entry(phrase: "註音", reading: "ㄓㄨˋ-ㄧㄣ", score: -2.5))
        XCTAssertEqual(UserPhrases(text: "").text, "")
    }

    func testTypedReadings() {
        XCTAssertEqual(UserPhrases.reading(fromTyped: "y42j/4"), "ㄗˋ-ㄉㄨㄥˋ")
        XCTAssertEqual(UserPhrases.reading(fromTyped: "ㄗˋㄉㄨㄥˋ"), "ㄗˋ-ㄉㄨㄥˋ")
        XCTAssertEqual(UserPhrases.reading(fromTyped: "ㄓㄨˋ ㄧㄣ"), "ㄓㄨˋ-ㄧㄣ")
        XCTAssertEqual(UserPhrases.reading(fromTyped: "ㄐㄧ-ㄚ"), "ㄐㄧ-ㄚ")      // first tone, then ㄚ
        XCTAssertEqual(UserPhrases.reading(fromTyped: "ㄉㄜ˙"), "ㄉㄜ˙")
        XCTAssertNil(UserPhrases.reading(fromTyped: "hello!"))
        XCTAssertNil(UserPhrases.reading(fromTyped: ""))
        XCTAssertEqual(UserPhrases.problem(phrase: "自動注音", reading: "ㄗˋ-ㄉㄨㄥˋ"), "注音有 2 個音節，詞有 4 個字")
        XCTAssertNil(UserPhrases.problem(phrase: "自動", reading: "ㄗˋ-ㄉㄨㄥˋ"))
    }

    func testLexiconUserPhrasesOverrideAndReload() {
        let lex = Lexicon()
        lex.load("ㄋㄧˇ 你 -2\nㄋㄧˇ 妳 -3\nㄏㄠˇ 好 -2\nㄋㄧˇ-ㄏㄠˇ 你好 -3\n")
        let ni = [Syllable(initial: "ㄋ", medial: "ㄧ", tone: .third)]
        XCTAssertEqual(lex.entries(for: ni).first?.phrase, "你")
        lex.setUserPhrases("ㄋㄧˇ 妳 -1\n")
        XCTAssertEqual(lex.entries(for: ni).map(\.phrase), ["妳", "你"])   // replaced, not duplicated
        XCTAssertEqual(lex.reading(of: "妳好"), "ㄋㄧˇ-ㄏㄠˇ")
        XCTAssertEqual(lex.reading(of: "你好"), "ㄋㄧˇ-ㄏㄠˇ")
        XCTAssertNil(lex.reading(of: "貓"))
        lex.setUserPhrases("")
        XCTAssertEqual(lex.entries(for: ni).map(\.phrase), ["你", "妳"])
        XCTAssertEqual(lex.entries(for: [Syllable(initial: "ㄋ", medial: "ㄧ")]).first?.phrase, "你")   // toneless
    }
}
