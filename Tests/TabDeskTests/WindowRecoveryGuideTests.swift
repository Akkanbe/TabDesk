import AppKit
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct WindowRecoveryGuideTests {
    @Test(arguments: AppLanguage.allCases)
    func recoveryHelpFitsOnScreen(language: AppLanguage) throws {
        try L10n.$languageOverride.withValue(language) {
            _ = NSApplication.shared
            let alert = WindowRecoveryGuide.alert(status: L10n.text(.recoverySearchResult, 12))
            alert.layout()
            let content = try #require(alert.window.contentView)
            #expect(alert.window.frame.height <= 800)
            #expect(alert.window.frame.width <= 800)
            for button in alert.buttons {
                #expect(content.bounds.contains(button.convert(button.bounds, to: content)))
            }
            if let prefix = ProcessInfo.processInfo.environment["TABDESK_RECOVERY_PREVIEW_PATH"] {
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "\(prefix)-\(language.rawValue).png"))
            }
        }
    }
}
