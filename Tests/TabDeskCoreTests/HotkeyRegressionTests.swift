import Foundation
import Testing
@testable import TabDeskCore

struct HotkeyRegressionTests {
    @Test func physicalKeyIdentityIgnoresAliasesAndModifierOrder() throws {
        let canonical = try HotkeyParser.parse("ctrl+alt+1")
        let aliases = try HotkeyParser.parse("control+option+1")
        let reordered = try HotkeyParser.parse("alt+ctrl+1")

        #expect(canonical == aliases)
        #expect(canonical == reordered)
        #expect(Set([canonical, aliases, reordered]).count == 1)
    }

    @Test func resolveRejectsAliasAndReorderedDuplicates() {
        let config = HotkeyConfig(
            activateTab: ["ctrl+alt+1", "control+option+1", "alt+ctrl+1"],
            nextTab: nil, previousTab: nil,
            registerFocusedWindow: nil,
            toggleEditMode: nil,
            toggleSidebar: nil)

        let (bindings, errors) = config.resolve()

        #expect(bindings.count == 1)
        #expect(bindings.first?.1 == .activateTab(1))
        #expect(errors.count == 2)
        #expect(errors.allSatisfy { $0.contains("重複") })
    }
}

struct HotkeyCycleConfigTests {
    @Test func defaultsIncludeTabCycling() {
        let (bindings, errors) = HotkeyConfig.default.resolve()
        #expect(errors.isEmpty)
        #expect(bindings.count == 14)  // タブ 1..9 + next/prev + 登録 + 編集モード + サイドバー折りたたみ
        #expect(bindings.contains { $0.1 == .nextTab })
        #expect(bindings.contains { $0.1 == .previousTab })
        #expect(bindings.contains { $0.1 == .toggleSidebar })
        #expect(try! HotkeyParser.parse("ctrl+tab").keyCode == 48)
    }

    /// 旧 hotkeys.json(toggleSidebar キーなし)は既定値で補われ、明示 null なら無効化できる。
    @Test func legacyConfigWithoutSidebarKeyGetsDefault() throws {
        let legacy = """
        {"activateTab":["ctrl+alt+1"],"registerFocusedWindow":"ctrl+alt+r","toggleEditMode":"ctrl+alt+e"}
        """
        let config = try JSONDecoder().decode(HotkeyConfig.self, from: Data(legacy.utf8))
        #expect(config.toggleSidebar == "ctrl+alt+s")

        let disabled = try JSONDecoder().decode(
            HotkeyConfig.self, from: Data(#"{"activateTab":[],"toggleSidebar":null}"#.utf8))
        #expect(disabled.toggleSidebar == nil)
    }

    @Test func legacyConfigWithoutCyclingKeysGetsDefaults() throws {
        // 旧バージョンが書いた hotkeys.json(nextTab / previousTab キーなし)
        let legacy = """
        {"activateTab":["ctrl+alt+1"],"registerFocusedWindow":"ctrl+alt+r","toggleEditMode":"ctrl+alt+e"}
        """
        let config = try JSONDecoder().decode(HotkeyConfig.self, from: Data(legacy.utf8))
        #expect(config.nextTab == "ctrl+tab", "missing keys fall back to defaults")
        #expect(config.previousTab == "ctrl+shift+tab")
        #expect(config.activateTab == ["ctrl+alt+1"])
    }

    @Test func explicitNullDisablesACycleKey() throws {
        let json = """
        {"activateTab":["ctrl+alt+1"],"nextTab":null,"previousTab":"ctrl+shift+tab",
         "registerFocusedWindow":null,"toggleEditMode":null}
        """
        let config = try JSONDecoder().decode(HotkeyConfig.self, from: Data(json.utf8))
        #expect(config.nextTab == nil, "explicit null means unassigned")
        #expect(config.previousTab == "ctrl+shift+tab")
        let (bindings, _) = config.resolve()
        #expect(bindings.count == 3)  // activateTab 1 + previousTab + toggleSidebar(キー無し = 既定)
    }
}
