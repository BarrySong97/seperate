import XCTest
@testable import Workbench

final class FuzzyTests: XCTestCase {
    func testSubsequenceMatchesAndMisses() {
        XCTAssertNotNil(Fuzzy.match("fhe", in: "Fetch History Export"))
        XCTAssertNil(Fuzzy.match("xyz", in: "Fetch History Export"))
        XCTAssertNotNil(Fuzzy.match("代码同步", in: "总结代码同步方式"))
        XCTAssertEqual(Fuzzy.match("", in: "anything")?.score, 0)
    }

    func testWordStartsRankHigherThanScatteredLetters() {
        XCTAssertGreaterThan(Fuzzy.match("fh", in: "fetch history")!.score, Fuzzy.match("fh", in: "offshore")!.score)
    }

    func testHighlightRangesCollapse() {
        XCTAssertEqual(Fuzzy.match("his", in: "history")?.ranges, [0..<3])
    }

    func testPinyinInitialsAndFullPinyinHighlightTheHanzi() {
        let title = "总结代码同步方式"
        let keys = Core.pinyinKeys(title)
        XCTAssertNotNil(keys)
        XCTAssertEqual(Fuzzy.matchTitle("dmtb", title, keys: keys)?.ranges, [2..<6])     // 代码同步
        XCTAssertEqual(Fuzzy.matchTitle("daima", title, keys: keys)?.ranges, [2..<4])    // 代码
        XCTAssertNil(Fuzzy.matchTitle("zzzz", title, keys: keys))
    }
}

final class PaletteSearchTests: XCTestCase {
    private func session(_ title: String, running: Bool = false, age: TimeInterval = 0, keys: [String] = []) -> PaletteEntry {
        PaletteEntry(kind: .session(title), section: .sessions, title: title, keys: keys, running: running,
                     recency: Date().addingTimeInterval(-age), pinyin: Core.pinyinKeys(title))
    }

    func testEmptyQueryShowsAllSessionsRunningThenRecentAndHidesCreate() {
        let entries = [session("旧的", age: 900), session("新的", age: 10), session("在跑", running: true, age: 500),
                       PaletteEntry(kind: .command("x", {}), section: .create, title: "新建 Codex")]
        let r = PaletteSearch.rank(entries, query: "")
        XCTAssertEqual(r.map(\.0), [.sessions])
        XCTAssertEqual(r[0].1.map(\.entry.title), ["在跑", "新的", "旧的"])
    }

    func testActiveWorkspaceRanksFirstOnEqualScore() {
        var other = session("修复登录", age: 1)
        other.local = false
        let mine = session("修复登录页", age: 999)
        XCTAssertEqual(PaletteSearch.rank([other, mine], query: "").first?.1.map(\.entry.title), ["修复登录页", "修复登录"])
    }

    func testQueryMatchesTitlePinyinAndExtraKeys() {
        let entries = [session("优化导出记录", keys: ["supply-smart-mono", "Codex"]), session("修复语言匹配", keys: ["listenup", "Claude"])]
        XCTAssertEqual(PaletteSearch.rank(entries, query: "yhdc").first?.1.map(\.entry.title), ["优化导出记录"])
        XCTAssertEqual(PaletteSearch.rank(entries, query: "claude").first?.1.map(\.entry.title), ["修复语言匹配"])
        XCTAssertTrue(PaletteSearch.rank(entries, query: "qqqq").isEmpty)
    }
}

final class RelativeTimeTests: XCTestCase {
    func testShortLabels() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))!
        let ago = { (s: TimeInterval) in RelativeTime.short(now.addingTimeInterval(-s), now: now, calendar: cal) }
        XCTAssertEqual(ago(20), "刚刚")
        XCTAssertEqual(ago(5 * 60), "5分钟")
        XCTAssertEqual(ago(3 * 3600), "3小时")
        XCTAssertEqual(ago(20 * 3600), "昨天")
        XCTAssertEqual(ago(4 * 86400), "4天")
        XCTAssertEqual(ago(12 * 86400), "9月12日")
        XCTAssertEqual(ago(400 * 86400), "2025年8月20日")
    }
}
