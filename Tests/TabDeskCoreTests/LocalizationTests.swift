import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

struct LocalizationTests {
    @Test func bothLanguagesHaveEveryKeyAndMatchingPlaceholders() throws {
        func strings(_ language: AppLanguage) throws -> [String: String] {
            let url = try #require(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
            let data = try Data(contentsOf: url)
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let japanese = try strings(.japanese)
        let english = try strings(.english)
        let keys = Set(L10n.Key.allCases.map(\.rawValue))
        #expect(Set(japanese.keys) == keys)
        #expect(Set(english.keys) == keys)
        for key in keys {
            let ja = try #require(japanese[key])
            let en = try #require(english[key])
            #expect(!ja.isEmpty && !en.isEmpty)
            #expect(ja.components(separatedBy: "%@").count == en.components(separatedBy: "%@").count)
            #expect(!en.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) || (0x4e00...0x9fff).contains($0.value) })
        }
    }

    @Test func preferencePersistsAndUnknownValuesFallBackToJapanese() throws {
        let suite = "TabDesk.LocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = LanguagePreference(defaults: defaults)
        #expect(setting.value == .japanese)
        setting.value = .english
        #expect(LanguagePreference(defaults: try #require(UserDefaults(suiteName: suite))).value == .english)
        defaults.set("unsupported", forKey: "DisplayLanguage")
        #expect(setting.value == .japanese)
        setting.value = .japanese
        #expect(setting.value == .japanese)
    }

    @Test @MainActor func newTabNamesFollowLanguageWithoutRenamingExistingTabs() throws {
        let engine = TabEngine(driver: FakeWindowDriver(), layout: FixedScreenLayout(
            parkPoint: CGPoint(x: 1919, y: 1199), contentArea: CGRect(x: 240, y: 30, width: 1680, height: 1090)))
        let first = L10n.$languageOverride.withValue(.japanese) { engine.createTab() }
        let custom = engine.createTab(name: "日本語 / English % @")
        let second = L10n.$languageOverride.withValue(.english) { engine.createTab() }
        #expect(engine.state.tab(withID: first.id)?.name == "タブ1")
        #expect(engine.state.tab(withID: custom.id)?.name == "日本語 / English % @")
        #expect(engine.state.tab(withID: second.id)?.name == "Tab 3")
        let title = L10n.$languageOverride.withValue(.english) {
            L10n.text(.windowsHeader, "日本語 % @", "12")
        }
        #expect(title == "日本語 % @ — Windows (12)")
    }
}
