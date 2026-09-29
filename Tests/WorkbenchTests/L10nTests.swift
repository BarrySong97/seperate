// @purpose Regression test: every Chinese UI string in Sources goes through tr("中文", "English").
// @role    XCTest scanning Sources/{Workbench,SeperateInstaller,SeperateHook} string literals.
// @deps    XCTest, Foundation
// @gotcha  Comments are skipped; lines that branch on L10n.isChinese may hold Chinese-only formats, and a
//          line marked `// l10n: <why>` (a language named in itself, data such as a demo title) is left alone.
//          ADR-0006, docs/modules/ui/README.md
import XCTest

final class L10nTests: XCTestCase {
    private struct Literal { let file: String; let line: Int; let text: String; let before: String }

    /// String literals per line, with the code before each one; `//` comments cut off.
    private func literals() throws -> [Literal] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var out: [Literal] = []
        for dir in ["Sources/Workbench", "Sources/SeperateInstaller", "Sources/SeperateHook"] {
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, dir)
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where !line.contains("L10n.isChinese") && !line.contains("// l10n:") {
                    var inString = false, escaped = false, start = line.startIndex, prev: Character = " "
                    var idx = line.startIndex
                    while idx < line.endIndex {
                        let c = line[idx]
                        if inString {
                            if escaped { escaped = false }
                            else if c == "\\" { escaped = true }
                            else if c == "\"" {
                                inString = false
                                let text = String(line[line.index(after: start)..<idx])
                                out.append(Literal(file: file.lastPathComponent, line: i + 1, text: text, before: String(line[..<start])))
                            }
                        } else if c == "\"" { inString = true; start = idx }
                        else if c == "/" && prev == "/" { break }
                        prev = c
                        idx = line.index(after: idx)
                    }
                }
            }
        }
        return out
    }

    private func hasHan(_ s: String) -> Bool { s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }

    func testChineseStringsAreWrappedInTr() throws {
        let bare = try literals().filter { hasHan($0.text) && !$0.before.hasSuffix("tr(") }
        XCTAssertEqual(bare.map { "\($0.file):\($0.line) \($0.text)" }, [],
                       "user-visible Chinese must be tr(\"中文\", \"English\")")
    }

    func testEnglishSideHasNoChinese() throws {
        // The literal right after `tr("…", ` is the English side.
        let english = try literals().filter { $0.before.range(of: #"tr\("(?:[^"\\]|\\.)*",\s*$"#, options: .regularExpression) != nil }
        XCTAssertFalse(english.isEmpty)
        let mixed = english.filter { hasHan($0.text) }
        XCTAssertEqual(mixed.map { "\($0.file):\($0.line) \($0.text)" }, [])
    }
}
