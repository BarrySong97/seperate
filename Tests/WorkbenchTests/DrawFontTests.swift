// @purpose Regression test: no view creates a system font inside draw(_:); they use Theme.font.
// @role    XCTest scanning Sources/Workbench/UI for NSFont constructors in draw(_:) bodies.
// @deps    XCTest, Foundation
// @gotcha  A font made per draw and dropped can come back nil and CoreText then throws while
//          measuring text (crashed ChipView). docs/modules/ui/README.md
import XCTest

final class DrawFontTests: XCTestCase {
    func testDrawMethodsUseCachedFonts() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Workbench/UI")
        let files = try FileManager.default.contentsOfDirectory(at: ui, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var depth = 0, inDraw = false
            for (i, line) in lines.enumerated() {
                if !inDraw, line.contains("func draw(_ dirtyRect") { inDraw = true; depth = 0 }
                guard inDraw else { continue }
                if line.contains("NSFont.") || line.contains("NSFont(") {
                    offenders.append("\(file.lastPathComponent):\(i + 1)")
                }
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if depth <= 0, line.contains("}") { inDraw = false }
            }
        }
        XCTAssertEqual(offenders, [], "use Theme.font(...) in draw(_:), not a fresh NSFont")
    }
}
