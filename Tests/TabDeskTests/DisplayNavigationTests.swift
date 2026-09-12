import AppKit
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct DisplayHotkeyIntegrationTests {
    @Test func rapidDisplayAndTabKeysKeepTheirAcceptedTargets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let displays = ["left", "right"].enumerated().map { index, id in
            let frame = CGRect(x: index * 1000, y: 0, width: 1000, height: 800)
            return DisplayLayout(id: id, frame: frame, contentArea: frame, parkPoint: CGPoint(x: 3000, y: 900))
        }
        var focus = DisplayNavigation.Focus(pid: 100, displayID: "left")
        let manager = WindowManager(logger: FileLogger(fileURL: directory.appendingPathComponent("test.log")),
            store: StateStore(fileURL: directory.appendingPathComponent("state.json")), monitoringEnabled: false,
            layout: FixedScreenLayout(displays: displays), displayFocusProvider: { focus })
        let left = (1...3).map { manager.engine.createTab(name: "L\($0)", on: "left") }
        let right = (1...3).map { manager.engine.createTab(name: "R\($0)", on: "right") }
        manager.navigate(.nextDisplay)
        #expect(manager.selectedDisplayID() == "right")
        manager.navigate(.nextTab)
        manager.navigate(.nextTab)
        manager.navigate(.previousDisplay)
        manager.navigate(.activateTab(2))
        // 古いフォーカス通知相当の観測値が残っていても受付先は変わらない。
        await manager.waitForNavigation()
        #expect(manager.engine.activeTabID(on: "right") == right[2].id)
        #expect(manager.engine.activeTabID(on: "left") == left[1].id)
        #expect(manager.selectedDisplayID() == "left")
        #expect(manager.displayFocusUnavailable == "left")
        manager.navigate(.nextDisplay)
        manager.navigate(.previousTab)
        await manager.waitForNavigation()
        #expect(manager.selectedDisplayID() == "right", "空タブでも選択を維持する")
        #expect(manager.engine.activeTabID(on: "right") == right[1].id)
        focus = .init(pid: 200, displayID: "left")
        #expect(manager.selectedDisplayID() == "left", "未登録アプリの手動フォーカスへ追従する")
    }
}
