import XCTest
import AppKit
@testable import Workbench

/// ⌘V in a terminal: text as is, files as escaped paths, a bare image saved to a PNG and pasted as its path.
final class PasteTests: XCTestCase {
    private let pb = NSPasteboard(name: .init("seperate-test-\(UUID().uuidString)"))
    override func tearDown() { pb.releaseGlobally() }

    @MainActor func testTextFilesAndImages() throws {
        pb.clearContents(); pb.setString("hello world", forType: .string)
        XCTAssertEqual(GhosttyRuntime.pasteText(pb), "hello world")

        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/My Shot (1).png") as NSURL])
        XCTAssertEqual(GhosttyRuntime.pasteText(pb), "/tmp/My\\ Shot\\ \\(1\\).png")

        pb.clearContents()
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        pb.writeObjects([img])
        let path = try XCTUnwrap(GhosttyRuntime.pasteText(pb))
        XCTAssertTrue(path.hasSuffix(".png"))
        let file = path.replacingOccurrences(of: "\\", with: "")
        XCTAssertNotNil(NSImage(contentsOfFile: file), "the pasted path is a real PNG")
        try? FileManager.default.removeItem(atPath: file)
    }
}
