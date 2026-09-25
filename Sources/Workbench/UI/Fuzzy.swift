import Foundation

/// Subsequence fuzzy matching for the command palette: every query character must appear in
/// order. Matches at the start, at word starts and in consecutive runs score higher.
/// Titles are also matched by pinyin (initials "dmtb" and full "daimatongbu" → 代码同步).
enum Fuzzy {
    struct Match: Equatable {
        let score: Int
        let hits: [Int]                     // matched character offsets in the original title
        var ranges: [Range<Int>] { Fuzzy.collapse(hits) }
    }

    static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Match(score: 0, hits: []) }
        let c = Array(candidate.lowercased())
        var qi = 0, score = 0, last = -2
        var hits: [Int] = []
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            score += 1
            if i == 0 { score += 6 }
            else if isBoundary(c[i - 1]) { score += 4 }
            if last == i - 1 { score += 3 }
            hits.append(i)
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        score -= min(c.count / 20, 3)   // shorter candidates win ties
        return Match(score: score, hits: hits)
    }

    /// Best of: the title itself, its pinyin initials, its full pinyin. Hits map back to title characters.
    static func matchTitle(_ query: String, _ title: String, keys: Core.PinyinKeys?) -> Match? {
        var best = match(query, in: title)
        guard let k = keys, k.full != title.lowercased() else { return best }
        func consider(_ m: Match?) { if let m, m.score > (best?.score ?? .min) { best = m } }
        // Initials are 1:1 with title characters; each initial also marks a word start.
        if let m = match(query, in: k.initials) { consider(Match(score: m.score + 2 * m.hits.count, hits: m.hits)) }
        if let m = match(query, in: k.full) {
            var seen = Set<Int>()
            let mapped = m.hits.compactMap { $0 < k.owner.count ? k.owner[$0] : nil }.filter { seen.insert($0).inserted }
            consider(Match(score: m.score - 1, hits: mapped))
        }
        return best
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "/" || ch == "." || ch == "·"
    }

    static func collapse(_ idx: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for i in idx.sorted() {
            if let r = out.last, r.upperBound == i { out[out.count - 1] = r.lowerBound..<(i + 1) } else { out.append(i..<(i + 1)) }
        }
        return out
    }
}
