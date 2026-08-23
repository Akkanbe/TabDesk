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

    /// スコア順に貪欲に割り当てる。各エントリ・各候補は 1 回しか使わない。
    public static func match(unbound: [ManagedWindow], candidates: [Candidate], strictness: Strictness) -> [Match] {
        let entriesByBundle = Dictionary(grouping: unbound, by: \.identity.bundleID)
        let candidatesByBundle = Dictionary(grouping: candidates, by: \.bundleID)

        var scored: [Match] = []
        for entry in unbound {
            let bundleID = entry.identity.bundleID
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
                if score >= strictness.threshold {
                    scored.append(Match(managedID: entry.id, candidate: candidate, score: score))
                }
            }
        }

        // スコアが高い順、同点なら保存順(unbound の並び)で安定させる。
        let order = Dictionary(uniqueKeysWithValues: unbound.enumerated().map { ($1.id, $0) })
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return (order[$0.managedID] ?? 0) < (order[$1.managedID] ?? 0)
        }

        var usedEntries = Set<UUID>()
        var usedWindows = Set<CGWindowID>()
        var result: [Match] = []
        for match in scored where !usedEntries.contains(match.managedID) && !usedWindows.contains(match.candidate.windowID) {
            usedEntries.insert(match.managedID)
            usedWindows.insert(match.candidate.windowID)
            result.append(match)
        }
        return result
    }
}
