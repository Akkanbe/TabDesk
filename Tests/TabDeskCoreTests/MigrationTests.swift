import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

/// v4 移行(migratedForPerDisplayTabs)の検証。純関数なのでエンジンなしで直接叩く。
struct MigrationTests {
    private let primary = "main"

    private func window(_ name: String, display: DisplayID?, bound: Bool = true) -> ManagedWindow {
        ManagedWindow(
            frame: CGRect(x: 300, y: 100, width: 500, height: 400),
            identity: WindowIdentity(bundleID: "test.\(name)", appName: name, title: name, registeredSize: CGSize(width: 500, height: 400)),
            windowID: bound ? CGWindowID.random(in: 1...99999) : nil,
            pid: bound ? 100 : nil,
            displayID: display)
    }

    @Test func splitKeepsNameAndSuffixesSiblings() {
        let w1 = window("a", display: nil)
        let w2 = window("b", display: "second")
        let w3 = window("c", display: nil)
        let tab = Tab(name: "Work", windows: [w1, w2, w3])
        let state = WorkspaceState(tabs: [tab], activeTabID: tab.id)

        let migrated = state.migratedForPerDisplayTabs(primaryID: primary)

        #expect(migrated.tabs.count == 2)
        #expect(migrated.tabs[0].name == "Work")
        #expect(migrated.tabs[0].id == tab.id, "最大グループが id を維持")
        #expect(migrated.tabs[0].windows.map(\.id) == [w1.id, w3.id])
        #expect(migrated.tabs[1].name == "Work (2)")
        #expect(migrated.tabs[1].windows.map(\.id) == [w2.id])
        #expect(migrated.tabs[1].displayID == "second")
    }

    @Test func keeperIsMajorityGroupWithFirstWindowTieBreak() {
        // 1:1 の同数 → 先頭の窓のグループ(second)が id/名前を維持する。
        let w1 = window("a", display: "second")
        let w2 = window("b", display: nil)
        let tab = Tab(name: "Mix", windows: [w1, w2])
        let migrated = WorkspaceState(tabs: [tab]).migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.tabs[0].id == tab.id)
        #expect(migrated.tabs[0].displayID == "second")
        #expect(migrated.tabs[1].name == "Mix (2)")
    }

    @Test func lastFocusedFollowsItsWindowGroup() {
        let w1 = window("a", display: nil)
        let w2 = window("b", display: "second")
        let tab = Tab(name: "Work", windows: [w1, w1, w2].map { $0 }, lastFocusedWindowID: w2.id)
        let migrated = WorkspaceState(tabs: [tab]).migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.tabs[0].lastFocusedWindowID == nil, "keeper 側には残らない")
        #expect(migrated.tabs[1].lastFocusedWindowID == w2.id, "窓と同じタブに付いていく")
    }

    @Test func layoutIsCopiedToSiblings() {
        let tab = Tab(name: "T", windows: [window("a", display: nil), window("b", display: "second")], layout: .columns)
        let migrated = WorkspaceState(tabs: [tab]).migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.tabs.allSatisfy { $0.layout == .columns })
    }

    @Test func singleDisplayTabIsUntouched() {
        let tab = Tab(name: "Solo", windows: [window("a", display: "second"), window("b", display: "second")])
        let migrated = WorkspaceState(tabs: [tab], activeTabID: tab.id).migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.tabs.count == 1)
        #expect(migrated.tabs[0].id == tab.id)
        #expect(migrated.tabs[0].name == "Solo")
        #expect(migrated.tabs[0].displayID == "second")
    }

    @Test func emptyTabPassesThroughOnPrimary() {
        let tab = Tab(name: "Empty")
        let migrated = WorkspaceState(tabs: [tab]).migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.tabs == [tab], "空タブは無変更(displayID nil = 主に載る)")
        #expect(migrated.activeTabIDs[primary] == tab.id, "主画面のアクティブとして播種される")
    }

    /// v1 純データ(全部 nil・主画面のみ)は nil のまま =「そのときの主」の意味を保つ。
    @Test func pureV1DataKeepsNilDisplay() {
        let tab = Tab(name: "Old", windows: [window("a", display: nil)])
        let migrated = WorkspaceState(tabs: [tab], activeTabID: tab.id).migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.tabs[0].displayID == nil)
        #expect(migrated.tabs[0].windows[0].displayID == nil)
        #expect(migrated.activeTabIDs[primary] == tab.id, "actives のキーは具体 ID")
        #expect(migrated.activeTabID == tab.id, "ミラー維持")
    }

    /// 切断中ディスプレイの窓は具体 ID を保持して独立タブになる(凍結タブとして復活を待つ)。
    @Test func disconnectedDisplayWindowsFormTheirOwnTab() {
        let gone = window("ext", display: "gone-display")
        let here = window("a", display: nil)
        let tab = Tab(name: "Work", windows: [here, gone])
        let migrated = WorkspaceState(tabs: [tab]).migratedForPerDisplayTabs(primaryID: primary)
        let frozen = migrated.tabs.first { $0.displayID == "gone-display" }
        #expect(frozen != nil)
        #expect(frozen?.windows.map(\.id) == [gone.id])
        #expect(migrated.activeTabIDs["gone-display"] == frozen?.id, "再接続時に active も復活できる")
    }

    @Test func windowDisplayIDIsSyncedToTab() {
        // 既移行の v4 タブではタブが正。窓側の古い・欠落した値で再分割してはいけない。
        let w1 = window("a", display: "second")
        let w2 = window("b", display: nil)
        let w3 = window("c", display: "main")
        let tab = Tab(name: "T", windows: [w1, w2, w3], displayID: "second")
        let migrated = WorkspaceState(tabs: [tab]).migratedForPerDisplayTabs(primaryID: primary)

        #expect(migrated.tabs.count == 1, "既移行タブを窓側の不整合で再分割しない")
        #expect(migrated.tabs[0].id == tab.id)
        #expect(migrated.tabs[0].displayID == "second")
        #expect(migrated.tabs[0].windows.allSatisfy { $0.displayID == "second" })
    }

    @Test func activesSeedFromLegacyThenFirstTabPerDisplay() {
        let t1 = Tab(name: "A", windows: [window("a", display: nil)])
        let t2 = Tab(name: "B", windows: [window("b", display: nil)])
        let t3 = Tab(name: "C", windows: [window("c", display: "second")])
        let state = WorkspaceState(tabs: [t1, t2, t3], activeTabID: t2.id)
        let migrated = state.migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.activeTabIDs[primary] == t2.id, "旧 activeTabID が優先")
        #expect(migrated.activeTabIDs["second"] == t3.id, "無い画面は先頭タブで補完")
        #expect(migrated.activeTabID == t2.id)
    }

    @Test func staleActiveEntriesAreCleaned() {
        let t1 = Tab(name: "A", windows: [window("a", display: nil)])
        let state = WorkspaceState(
            tabs: [t1], activeTabID: nil,
            activeTabIDs: ["second": UUID(), primary: t1.id])  // second のタブは存在しない
        let migrated = state.migratedForPerDisplayTabs(primaryID: primary)
        #expect(migrated.activeTabIDs == [primary: t1.id])
    }

    @Test func migrationIsIdempotent() {
        let tab = Tab(name: "Work", windows: [
            window("a", display: nil), window("b", display: "second"), window("c", display: "third"),
        ])
        let once = WorkspaceState(tabs: [tab], activeTabID: tab.id).migratedForPerDisplayTabs(primaryID: primary)
        let twice = once.migratedForPerDisplayTabs(primaryID: primary)
        #expect(once == twice)
    }

    @Test func nilPrimaryReturnsSelf() {
        let tab = Tab(name: "T", windows: [window("a", display: nil), window("b", display: "second")])
        let state = WorkspaceState(tabs: [tab])
        #expect(state.migratedForPerDisplayTabs(primaryID: nil) == state, "画面が無ければ何もしない")
    }

    // MARK: - デコード互換

    /// v3 以前の state.json(displayID / activeTabIDs キーなし)が読める。
    @Test func decodesV3FileWithoutNewKeys() throws {
        let json = """
            {"version": 1, "activeTabID": "\(UUID().uuidString)", "tabs": [
              {"id": "\(UUID().uuidString)", "name": "Work", "windows": []}
            ]}
            """
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.tabs[0].displayID == nil)
        #expect(state.activeTabIDs.isEmpty)
    }

    @Test func newFieldsRoundTripThroughCoding() throws {
        let tab = Tab(name: "T", displayID: "second")
        let state = WorkspaceState(tabs: [tab], activeTabID: tab.id, activeTabIDs: ["second": tab.id])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.tabs[0].displayID == "second")
        #expect(decoded.activeTabIDs == ["second": tab.id])
        #expect(decoded.activeTabID == tab.id, "旧フィールドも書かれている(ダウングレード耐性)")
    }
}
