import AppKit
import Carbon.HIToolbox
import TabDeskCore

/// グローバルホットキー。設定は hotkeys.json(手で編集可)から読み、`reload()` で登録し直す。
/// Carbon の RegisterEventHotKey を直接使う(依存追加なし。アクセサリアプリでも全画面から届く)。
@MainActor
final class HotkeyCenter {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TabDesk/hotkeys.json")

    var onAction: (@MainActor (HotkeyAction) -> Void)?

    private let logger: FileLogger
    private var handlerRef: EventHandlerRef?
    private var registeredRefs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]

    init(logger: FileLogger) {
        self.logger = logger
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &eventType, refcon, &handlerRef)
        if status != noErr {
            logger.log("hotkeys: InstallEventHandler failed (OSStatus \(status))")
        }
    }

    /// 設定を読み(無ければ既定を書き出し)、ホットキーを登録し直す。
    func reload() {
        for ref in registeredRefs {
            UnregisterEventHotKey(ref)
        }
        registeredRefs.removeAll()
        actionsByID.removeAll()

        var config = HotkeyConfig.default
        do {
            if let loaded = try HotkeyConfig.load(from: Self.configURL) {
                config = loaded
            } else {
                try config.save(to: Self.configURL)
                logger.log("hotkeys: wrote default config to \(Self.configURL.path)")
            }
        } catch {
            // 壊れた設定でもアプリは動かす(既定にフォールバック)。ファイルは直せるよう残す。
            logger.log("hotkeys: config unreadable (\(error)); using defaults")
        }

        let (bindings, errors) = config.resolve()
        for message in errors {
            logger.log("hotkeys: \(message)")
        }
        var id: UInt32 = 1
        for (hotkey, action) in bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5442_4B31) /* 'TBK1' */, id: id)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registeredRefs.append(ref)
                actionsByID[id] = action
            } else {
                logger.log("hotkeys: could not register \(hotkey.display) (OSStatus \(status)) — 他アプリが使用中の可能性")
            }
            id += 1
        }
        logger.log("hotkeys: \(registeredRefs.count) binding(s) active")
    }

    fileprivate func dispatch(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        onAction?(action)
    }
}

/// Carbon のイベントハンドラ(メインスレッドで呼ばれる)。refcon から HotkeyCenter を復元して転送する。
private let hotkeyEventHandler: EventHandlerUPP = { _, event, refcon in
    guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        center.dispatch(id: id)
    }
    return noErr
}
