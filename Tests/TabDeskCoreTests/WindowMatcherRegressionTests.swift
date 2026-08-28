import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

private let regressionSize = CGSize(width: 800, height: 600)
private let regressionFrame = CGRect(x: 240, y: 30, width: 800, height: 600)

private func regressionEntry(
    bundleID: String = "test.browser", title: String, size: CGSize = regressionSize
) -> ManagedWindow {
    ManagedWindow(
        frame: regressionFrame,
        identity: WindowIdentity(bundleID: bundleID, appName: "Browser", title: title, registeredSize: size),
        windowID: nil,
        pid: nil)
}

private func regressionCandidate(
    _ windowID: CGWindowID, bundleID: String = "test.browser", title: String,
    size: CGSize = regressionSize
) -> WindowMatcher.Candidate {
    WindowMatcher.Candidate(
        windowID: windowID,
        pid: pid_t(windowID),
        bundleID: bundleID,
        title: title,
        size: size)
}

struct WindowMatcherRegressionTests {
    @Test func candidateOrderDoesNotChangeTheUniqueBestMatch() {
        let entry = regressionEntry(title: "Untitled")
        let exactWithSize = regressionCandidate(1, title: "Untitled")
        let exactWithoutSize = regressionCandidate(
            2, title: "Untitled", size: CGSize(width: 1200, height: 900))

        let forward = WindowMatcher.match(
            unbound: [entry], candidates: [exactWithSize, exactWithoutSize], strictness: .strict)
        let reversed = WindowMatcher.match(
            unbound: [entry], candidates: [exactWithoutSize, exactWithSize], strictness: .strict)

        #expect(forward.map(\.candidate.windowID) == [1])
        #expect(reversed.map(\.candidate.windowID) == [1])
    }

    @Test func oneEntryWithTwoEqualBestCandidatesStaysUnbound() {
        let entry = regressionEntry(title: "Untitled")
        let candidates = [
            regressionCandidate(1, title: "Untitled"),
            regressionCandidate(2, title: "Untitled"),
        ]

        #expect(WindowMatcher.match(unbound: [entry], candidates: candidates, strictness: .strict).isEmpty)
        #expect(WindowMatcher.match(unbound: [entry], candidates: Array(candidates.reversed()), strictness: .strict).isEmpty)
    }

    @Test func fullyTiedTwoByTwoStaysUnbound() {
        let entries = [
            regressionEntry(title: "Untitled"),
            regressionEntry(title: "Untitled"),
        ]
        let candidates = [
            regressionCandidate(1, title: "Untitled"),
            regressionCandidate(2, title: "Untitled"),
        ]

        #expect(WindowMatcher.match(unbound: entries, candidates: candidates, strictness: .strict).isEmpty)
    }

    @Test func candidateSharedByEqualBestEntriesIsNotGuessed() {
        let entries = [
            regressionEntry(title: "Untitled"),
            regressionEntry(title: "Untitled"),
        ]
        let candidates = [
            regressionCandidate(1, title: "Untitled"),
            regressionCandidate(2, title: "Untitled", size: CGSize(width: 1200, height: 900)),
        ]

        #expect(WindowMatcher.match(unbound: entries, candidates: candidates, strictness: .strict).isEmpty)
    }

    @Test func emptyBundleIDNeverMatchesAutomatically() {
        let entry = regressionEntry(bundleID: "", title: "Untitled")
        let candidate = regressionCandidate(1, bundleID: "", title: "Untitled")

        #expect(WindowMatcher.match(unbound: [entry], candidates: [candidate], strictness: .lenient).isEmpty)
        #expect(WindowMatcher.match(unbound: [entry], candidates: [candidate], strictness: .strict).isEmpty)
    }

    @Test func exactTitleTwoByTwoStillProducesTheUniqueAssignment() {
        let github = regressionEntry(title: "GitHub")
        let docs = regressionEntry(title: "Docs")
        let candidates = [
            regressionCandidate(1, title: "Docs"),
            regressionCandidate(2, title: "GitHub"),
        ]

        let matches = WindowMatcher.match(unbound: [github, docs], candidates: candidates, strictness: .strict)

        #expect(matches.count == 2)
        #expect(matches.first { $0.managedID == github.id }?.candidate.windowID == 2)
        #expect(matches.first { $0.managedID == docs.id }?.candidate.windowID == 1)
    }
}
