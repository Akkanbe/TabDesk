import CoreGraphics
import Foundation

/// 再起動後に「保存されたエントリ」と「今ある窓」を突き合わせる。
///
/// CGWindowID は再起動をまたいで安定しないので、bundle ID・タイトル・サイズのヒューリスティックで推定する。
/// 完全復元は原理的に不可能なので、確度の低い候補は紐付けず「未復元」として残す。
public enum WindowMatcher {
    public struct Candidate: Sendable, Hashable {
        public let windowID: CGWindowID
        public let pid: pid_t
        public let bundleID: String
        public let title: String
        public let size: CGSize

        public init(windowID: CGWindowID, pid: pid_t, bundleID: String, title: String, size: CGSize) {
            self.windowID = windowID
            self.pid = pid
            self.bundleID = bundleID
            self.title = title
            self.size = size
        }
    }

    public struct Match: Sendable, Hashable {
        public let managedID: UUID
        public let candidate: Candidate
        public let score: Int
    }

    /// 紐付けの厳しさ。起動直後は緩め(保存時の窓がそのまま残っている可能性が高い)、
    /// 稼働中の自動紐付けは厳しめ(誤った窓を掴んでタブに引き込む事故を避ける)。
    public enum Strictness: Sendable {
        case lenient
        case strict

        var threshold: Int {
            switch self {
            case .lenient: return 2
            case .strict: return 4
            }
        }
    }

    static let exactTitleScore = 4
    static let partialTitleScore = 2
    static let sizeScore = 1
    static let uniquenessScore = 2
    static let sizeTolerance: CGFloat = 2

    /// entry と候補の双方から見て、最高点が一意な組み合わせだけを割り当てる。
    /// 同点を列挙順で決めると別の窓を動かすため、曖昧な組み合わせは未復元のまま残す。
    public static func match(unbound: [ManagedWindow], candidates: [Candidate], strictness: Strictness) -> [Match] {
        let entriesByBundle = Dictionary(grouping: unbound, by: \.identity.bundleID)
        let candidatesByBundle = Dictionary(grouping: candidates, by: \.bundleID)

        var allEdges: [Match] = []
        for entry in unbound {
            let bundleID = entry.identity.bundleID
            // bundle ID は自動再同定の必須条件。空文字をひとつのアプリとして束ねると、
            // bundle ID を取得できない別アプリ同士を誤って紐付けてしまう。
            guard !bundleID.isEmpty else { continue }
            guard let sameApp = candidatesByBundle[bundleID] else { continue }
            // 「そのアプリの保存エントリも今の窓も 1 つだけ」なら、タイトルが変わっていても同じ窓とみなしやすい。
            let unique = entriesByBundle[bundleID]?.count == 1 && sameApp.count == 1
            for candidate in sameApp {
                var score = 0
                let saved = entry.identity.title
                if !saved.isEmpty, saved == candidate.title {
                    score += exactTitleScore
                } else if !saved.isEmpty, !candidate.title.isEmpty,
                    candidate.title.hasPrefix(saved) || saved.hasPrefix(candidate.title)
                        || candidate.title.contains(saved) || saved.contains(candidate.title)
                {
                    score += partialTitleScore
                }
                if abs(candidate.size.width - entry.identity.registeredSize.width) <= sizeTolerance
                    && abs(candidate.size.height - entry.identity.registeredSize.height) <= sizeTolerance
                {
                    score += sizeScore
                }
                if unique {
                    score += uniquenessScore
                }
                allEdges.append(Match(managedID: entry.id, candidate: candidate, score: score))
            }
        }

        func uniqueBest<Key: Hashable>(
            _ groups: [Key: [Match]]
        ) -> [Key: Match] {
            groups.compactMapValues { edges in
                guard let highest = edges.map(\.score).max() else { return nil }
                let best = edges.filter { $0.score == highest }
                return best.count == 1 ? best[0] : nil
            }
        }

        let bestForEntry = uniqueBest(Dictionary(grouping: allEdges, by: \.managedID))
        let bestForCandidate = uniqueBest(Dictionary(grouping: allEdges, by: { $0.candidate.windowID }))

        // allEdges は保存順で作っている。採用判断は順序に依存せず、返却順だけを安定させる。
        return allEdges.filter { edge in
            edge.score >= strictness.threshold
                && bestForEntry[edge.managedID] == edge
                && bestForCandidate[edge.candidate.windowID] == edge
        }
    }
}
