import Foundation

extension WorkspaceState {
    /// v4: タブをディスプレイ単位に正規化する(純関数・冪等。docs/06_v4_design.md)。
    ///
    /// - `Tab.displayID` が無い旧タブに複数ディスプレイの窓が混在する場合、窓の実効ディスプレイ
    ///   (`displayID ?? primaryID`)で自動分割する。最大グループ(同数なら先頭の窓のグループ)が
    ///   元の id と名前を維持し、兄弟は「名前 (2)」…の連番で直後に挿入される
    /// - `Tab.displayID` がある既移行データはタブを正とし、窓側の displayID だけを揃える
    /// - 空タブは素通し(displayID は現状維持 = 通常 nil で主ディスプレイに載る)
    /// - v1 純データ(タブも窓も displayID が nil で主画面のみ)は nil のまま =「そのときの主」の
    ///   意味を保ち、主画面の役割が移っても凍結しない
    /// - タブ確定後、全窓の displayID をタブの値に揃える(v4 の不変量)
    /// - actives: 既存 activeTabIDs の掃除 → 旧 activeTabID の播種 → 各画面の先頭タブで補完。
    ///   旧 activeTabID は主ディスプレイのアクティブのミラーとして更新される
    ///
    /// TabEngine.init が毎回適用する(冪等なのでコストは分割が必要なときだけ)。
    public func migratedForPerDisplayTabs(primaryID: DisplayID?) -> WorkspaceState {
        guard let primaryID else { return self }

        var newTabs: [Tab] = []
        for tab in tabs {
            // displayID を持つタブは既に v4 の所属が確定しているため、タブ側を正として
            // 窓の欠落・古い値だけを修復する。窓側の不整合で再分割するとタブの ID・名前・
            // active が意図せず別画面へ移ってしまう。
            if let displayID = tab.displayID {
                var normalized = tab
                normalized.windows = tab.windows.map { window in
                    var window = window
                    window.displayID = displayID
                    return window
                }
                newTabs.append(normalized)
                continue
            }
            guard !tab.windows.isEmpty else {
                newTabs.append(tab)
                continue
            }
            // 実効ディスプレイでグループ化(窓の並び順・グループの出現順を維持)。
            var groupOrder: [DisplayID] = []
            var groups: [DisplayID: [ManagedWindow]] = [:]
            for window in tab.windows {
                let key = window.displayID ?? primaryID
                if groups[key] == nil { groupOrder.append(key) }
                groups[key, default: []].append(window)
            }
            // 最大グループが元の id / 名前を維持(同数なら先頭の窓のグループ = groupOrder の先勝ち)。
            var keeperKey = groupOrder[0]
            for key in groupOrder.dropFirst() where groups[key]!.count > groups[keeperKey]!.count {
                keeperKey = key
            }
            var suffix = 2
            for key in [keeperKey] + groupOrder.filter({ $0 != keeperKey }) {
                let windows = groups[key]!
                let isKeeper = key == keeperKey
                // v1 純データ(主画面・全部 nil・タブも nil)は nil を保つ。それ以外は具体 ID で固定。
                let tabDisplayID: DisplayID? =
                    (key == primaryID && tab.displayID == nil && windows.allSatisfy { $0.displayID == nil })
                    ? nil : key
                let normalized = windows.map { window in
                    var w = window
                    w.displayID = tabDisplayID
                    return w
                }
                let containsLastFocused = tab.lastFocusedWindowID.map { id in
                    windows.contains { $0.id == id }
                } ?? false
                newTabs.append(Tab(
                    id: isKeeper ? tab.id : UUID(),
                    name: isKeeper ? tab.name : "\(tab.name) (\(suffix))",
                    windows: normalized,
                    lastFocusedWindowID: containsLastFocused ? tab.lastFocusedWindowID : nil,
                    layout: tab.layout,
                    displayID: tabDisplayID))
                if !isKeeper { suffix += 1 }
            }
        }

        // actives: 掃除 → 旧 activeTabID の播種 → 各画面の先頭タブで補完。
        func resolvedKey(_ tab: Tab) -> DisplayID { tab.displayID ?? primaryID }
        var actives = activeTabIDs.filter { key, tabID in
            guard let tab = newTabs.first(where: { $0.id == tabID }) else { return false }
            return resolvedKey(tab) == key
        }
        if let legacy = activeTabID, let tab = newTabs.first(where: { $0.id == legacy }) {
            actives[resolvedKey(tab)] = actives[resolvedKey(tab)] ?? tab.id
        }
        for tab in newTabs where actives[resolvedKey(tab)] == nil {
            actives[resolvedKey(tab)] = tab.id
        }

        var out = self
        out.tabs = newTabs
        out.activeTabIDs = actives
        out.activeTabID = actives[primaryID]  // 旧フィールドは主ディスプレイのミラー
        return out
    }
}
