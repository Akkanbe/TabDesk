import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case japanese = "ja"
    case english = "en"

    public var nativeName: String { self == .japanese ? "日本語" : "English" }
}

/// 言語設定はワークスペースやホットキーの保存とは独立させる。
public struct LanguagePreference {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var value: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: "DisplayLanguage") ?? "") ?? .japanese }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "DisplayLanguage") }
    }
}

public enum L10n {
    // テストは利用者の設定を書き換えず、タスクごとに言語を指定できる。
    @TaskLocal public static var languageOverride: AppLanguage?
    public static var language: AppLanguage { languageOverride ?? LanguagePreference().value }

    public enum Key: String, CaseIterable, Sendable {
        case nextDisplay
        case previousDisplay
        case selectedDisplay
        case displayFocusUnavailable
        case layoutTiled
        case duplicateTileLayout
        case copiedTabName
        case undoTileEdit
        case redoTileEdit
        case tileIssueItem
        case tileIssuesTitle
        case tileIssuesHelp
        case selectIssueTile
        case tileIssuesSummary
        case editTiles
        case tileEditorTitle
        case tileEditorHelp
        case splitLeftRight
        case splitTopBottom
        case mergeTiles
        case applyTiles
        case reloadTiles
        case tileNumber
        case emptyTile
        case tileAssignment
        case addToTile
        case tileDraft
        case tilesApplied
        case tileFitWarning
        case invalidTiles
        case noEmptyTile
        case occupiedMerge
        case cannotMerge
        case tilesTooSmall
        case tileOperationFailed
        case tileTabUnavailable
        case tileSuffix
        case windowOperationFailed
        case showSidebar
        case collapseSidebar
        case unregisteredWindowsOnTop
        case alwaysOnTop
        case followFocus
        case launchAtLogin
        case showFrames
        case showThumbnails
        case allowURLs
        case openHotkeys
        case revealHotkeys
        case reloadHotkeys
        case openAccessibility
        case openLog
        case windowRecovery
        case windowRecoveryHelp
        case retryWindowSearch
        case recoveryPermissionRequired
        case recoverySearchResult
        case quit
        case loginApproval
        case loginUnavailable
        case loginUnknown
        case saveFailedMenu
        case saveStoppedMenu
        case saveErrorAccessibility
        case saveErrorTooltip
        case saveErrorTitle
        case close
        case openSaveFolder
        case retry
        case hotkeyApplyError
        case addWindow
        case editMode
        case expandSidebar
        case addTab
        case accessibilityHelp
        case requestPermission
        case captureHelp
        case openCapture
        case emptyTabsHint
        case columnsSuffix
        case noTabs
        case loading
        case noAvailableWindows
        case noAssignableWindows
        case renameTab
        case rename
        case cancel
        case sidebarWidth
        case moveUp
        case moveDown
        case layoutFree
        case layoutColumns
        case renameAction
        case deleteTab
        case unrestored
        case disconnected
        case removeWindow
        case saveHotkeys
        case defaultHotkeys
        case hotkeySettings
        case hotkeyInstructions
        case hotkeyNotSaved
        case hotkeySaved
        case hotkeyPartial
        case defaultsFilled
        case recordingFailed
        case recordingInstructions
        case monitorFailed
        case recordingCancelled
        case modifierRequired
        case unsupportedKey
        case recorded
        case cleared
        case resumeFailed
        case resumeHelp
        case hotkeyHelp
        case nextTab
        case previousTab
        case registerFocused
        case toggleEdit
        case toggleSidebar
        case clearShortcut
        case pressShortcut
        case clickToRecord
        case hotkeysStopping
        case recordingStopping
        case handlerFailed
        case saveLocation
        case windowsHeader
        case unmanageable
        case renamePrompt
        case assignWindowHelp
        case disconnectedHelp
        case hotkeyLoadError
        case hotkeySaveError
        case activateTab
        case clearShortcutLabel
        case hotkeyLoadFallback
        case hotkeyRegisterError
        case hotkeyUnregisterError
        case duplicateHotkey
        case stateBackupError
        case stateSaveError
        case defaultTabName
        case editModeHelp
    }

    private static let resourceBundle: Bundle = {
        // SwiftPM の実行と、Contents/Resources に同梱した配布用 .app の両方を扱う。
        if let url = Bundle.main.resourceURL?.appendingPathComponent("TabDesk_TabDeskCore.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static func bundle(for language: AppLanguage) -> Bundle {
        guard let url = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing localization resources: \(language.rawValue)")
        }
        return bundle
    }

    public static func text(_ key: Key, _ arguments: CVarArg...) -> String {
        let format = bundle(for: language).localizedString(forKey: key.rawValue, value: nil, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}
