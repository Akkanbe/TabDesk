import CoreGraphics
import Testing
@testable import TabDeskCore

struct WindowServerMatchTests {
    private let frame = CGRect(x: 100, y: 100, width: 500, height: 300)

    @Test func identicalOverlappingWindowsAreNeverJoined() {
        let refs = [1, 2].map { WindowServerMatch.Reference(id: WindowReferenceID(integerLiteral: $0), pid: 100, frame: frame, title: "Same") }
        let candidates = [10, 20].map { WindowServerMatch.Candidate(number: $0, pid: 100, frame: frame, title: "Same") }
        #expect(WindowServerMatch.match(1, references: refs, candidates: candidates) == nil)
        // 一方の一覧から窓が欠けても、逆向きの曖昧さを見落とさない。
        #expect(WindowServerMatch.match(1, references: refs, candidates: Array(candidates.prefix(1))) == nil)
    }

    @Test func uniqueTitleSeparatesOverlappingWindows() {
        let refs = [WindowServerMatch.Reference(id: 1, pid: 100, frame: frame, title: "A"),
                    WindowServerMatch.Reference(id: 2, pid: 100, frame: frame, title: "B")]
        let candidates = [WindowServerMatch.Candidate(number: 10, pid: 100, frame: frame, title: "A"),
                          WindowServerMatch.Candidate(number: 20, pid: 100, frame: frame, title: "B")]
        #expect(WindowServerMatch.match(1, references: refs, candidates: candidates) == 10)
        #expect(WindowServerMatch.match(2, references: refs, candidates: candidates) == 20)
    }

    @Test func missingTitlesDoNotResolveOverlappingWindows() {
        let refs = [WindowServerMatch.Reference(id: 1, pid: 100, frame: frame, title: "A"),
                    WindowServerMatch.Reference(id: 2, pid: 100, frame: frame, title: "B")]
        let candidates = [WindowServerMatch.Candidate(number: 10, pid: 100, frame: frame, title: nil)]
        #expect(WindowServerMatch.match(1, references: refs, candidates: candidates) == nil)
    }

    @Test func anotherProcessOrChangedFrameCannotMatch() {
        let ref = WindowServerMatch.Reference(id: 1, pid: 100, frame: frame, title: "Same")
        #expect(WindowServerMatch.match(1, references: [ref], candidates: [
            .init(number: 10, pid: 200, frame: frame, title: "Same")]) == nil)
        #expect(WindowServerMatch.match(1, references: [ref], candidates: [
            .init(number: 10, pid: 100, frame: frame.offsetBy(dx: 10, dy: 0), title: "Same")]) == nil)
    }
}
