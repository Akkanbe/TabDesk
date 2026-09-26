import AppKit
import ApplicationServices

/// 撮影・診断・表示順序の補助照合。CG番号からAX参照を作ったり、消滅判定に使ったりしない。
public enum WindowServerMatch {
    struct Candidate: Equatable {
        let number: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let title: String?
    }
    struct Reference {
        let id: WindowReferenceID
        let pid: pid_t
        let frame: CGRect
        let title: String?
    }

    static func match(_ id: WindowReferenceID, references: [Reference], candidates: [Candidate], requireTitleMatch: Bool = true) -> CGWindowID? {
        func agrees(_ reference: Reference, _ candidate: Candidate) -> Bool {
            guard reference.pid == candidate.pid,
                  ScreenGeometry.approximatelyEqual(reference.frame, candidate.frame, tolerance: 1) else { return false }
            if requireTitleMatch, let a = reference.title, let b = candidate.title, !a.isEmpty, !b.isEmpty { return a == b }
            return true
        }
        guard let target = references.first(where: { $0.id == id }) else { return nil }
        let matches = candidates.filter { agrees(target, $0) }
        guard matches.count == 1, let candidate = matches.first,
              references.filter({ agrees($0, candidate) }).count == 1 else { return nil }
        return candidate.number
    }

    /// 両側の一覧を毎回読み直す。同名・同位置や読み取り不足なら撮影を省略する。
    /// 表示順序の判定ではタイトル更新の遅延を許容できるが、両方向の一意性は必須。
    /// 撮影・既存URL操作は既定の厳格照合を維持する。
    public static func windowNumber(for window: AXWindow, requireTitleMatch: Bool = true) -> CGWindowID? {
        let root = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let elements = try? AXAttributes.elements(root, kAXWindowsAttribute) else { return nil }
        var references: [Reference] = []
        for element in elements {
            guard let candidate = try? AXWindow(element: element, pid: window.pid),
                  let frame = try? candidate.frame() else { return nil }
            references.append(Reference(id: candidate.windowID, pid: candidate.pid, frame: frame,
                title: try? AXAttributes.string(element, kAXTitleAttribute)))
        }
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var candidates: [Candidate] = []
        for entry in info {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            guard pid == window.pid else { continue }
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            guard layer == 0 else { continue }
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            candidates.append(Candidate(number: number, pid: pid, frame: frame, title: entry[kCGWindowName as String] as? String))
        }
        guard let number = match(window.windowID, references: references, candidates: candidates, requireTitleMatch: requireTitleMatch),
              let sampled = references.first(where: { $0.id == window.windowID }),
              (try? window.frame()) == sampled.frame else { return nil }
        return number
    }
}
