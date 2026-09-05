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
    private let fileURL: URL
    // テストではOSの登録だけを差し替え、利用中のグローバルキーを奪わず復帰・失敗を検証する。
    private let registerKey: (Hotkey, UInt32) -> (OSStatus, EventHotKeyRef?)
    private let unregisterKey: (EventHotKeyRef) -> OSStatus
    private var handlerRef: EventHandlerRef?
    private var registeredRefs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var isStopped = false
    private var isSuspended = false
    private var currentBindings: [(Hotkey, HotkeyAction)] = []

    init(
        logger: FileLogger,
        fileURL: URL = HotkeyCenter.configURL,
        registerKey: @escaping (Hotkey, UInt32) -> (OSStatus, EventHotKeyRef?) = { hotkey, id in
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5442_4B31) /* 'TBK1' */, id: id)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            return (status, ref)
        },
        unregisterKey: @escaping (EventHotKeyRef) -> OSStatus = { UnregisterEventHotKey($0) }
    ) {
        self.logger = logger
        self.fileURL = fileURL
        self.registerKey = registerKey
        self.unregisterKey = unregisterKey
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &eventType, refcon, &handlerRef)
        if status != noErr {
            logger.log("hotkeys: InstallEventHandler failed (OSStatus \(status))")
        }
    }

    /// 設定を読み(無ければ既定を書き出し)、ホットキーを登録し直す。
    @discardableResult
    func reload() -> [String] {
        guard !isStopped else {
            logger.log("hotkeys: reload ignored after stop")
            return ["終了処理中のためホットキーを変更できません。"]
        }
        var config = HotkeyConfig.default
        var issues: [String] = []
        do {
            if let loaded = try HotkeyConfig.load(from: fileURL) {
                config = loaded
            } else {
                try config.save(to: fileURL)
                logger.log("hotkeys: wrote default config to \(fileURL.path)")
            }
        } catch {
            // 壊れた設定でもアプリは動かす(既定にフォールバック)。ファイルは直せるよう残す。
            logger.log("hotkeys: config unreadable (\(error)); using defaults")
            issues.append("設定を読み込めないため既定値を使用しています：\(error)")
        }

        let (bindings, errors) = config.resolve()
        currentBindings = bindings
        issues.append(contentsOf: errors)
        for message in errors { logger.log("hotkeys: \(message)") }
        if !isSuspended { issues.append(contentsOf: registerCurrentBindings()) }
        return issues
    }

    /// 記録するキーをCarbonが先取りしないよう、記録中だけ登録を解除する。
    func suspendForRecording() -> [String] {
        guard !isStopped else { return ["終了処理中のため記録できません。"] }
        isSuspended = true
        return unregisterHotkeys()
    }

    func resumeAfterRecording() -> [String] {
        guard isSuspended else { return [] }
        isSuspended = false
        guard !isStopped else { return [] }
        return registerCurrentBindings()
    }

    private func registerCurrentBindings() -> [String] {
        var issues = unregisterHotkeys()
        // 解除できなかった参照と新しい登録が重ならないよう、再登録を止める。
        guard issues.isEmpty else { return issues }
        if handlerRef == nil {
            issues.append("ホットキーのイベントハンドラを登録できません。アプリを再起動してください。")
            return issues
        }
        var id: UInt32 = 1
        for (hotkey, action) in currentBindings {
            let (status, ref) = registerKey(hotkey, id)
            if status == noErr, let ref {
                registeredRefs.append(ref)
                actionsByID[id] = action
            } else {
                logger.log("hotkeys: could not register \(hotkey.display) (OSStatus \(status)) — 他アプリが使用中の可能性")
                issues.append("\(hotkey.display)：登録できません（OSStatus \(status)）。他アプリの割り当てを確認してください。")
            }
            id += 1
        }
        logger.log("hotkeys: \(registeredRefs.count) binding(s) active")
        return issues
    }

    /// 終了要求を受けたら、新しいホットキー操作が実窓の復元後に割り込まないよう同期的に停止する。
    /// AppKit から終了要求が複数回来ても安全なよう、2 回目以降は何もしない。
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        onAction = nil
        unregisterHotkeys()
        if let handlerRef {
            let status = RemoveEventHandler(handlerRef)
            if status != noErr {
                logger.log("hotkeys: RemoveEventHandler failed (OSStatus \(status))")
            }
            self.handlerRef = nil
        }
        logger.log("hotkeys: stopped")
    }

    @discardableResult
    private func unregisterHotkeys() -> [String] {
        var remaining: [EventHotKeyRef] = []
        var issues: [String] = []
        for ref in registeredRefs {
            let status = unregisterKey(ref)
            if status != noErr {
                logger.log("hotkeys: UnregisterEventHotKey failed (OSStatus \(status))")
                remaining.append(ref)
                issues.append("ホットキーを一時解除できません（OSStatus \(status)）。")
            }
        }
        registeredRefs = remaining
        actionsByID.removeAll()
        return issues
    }

    fileprivate func dispatch(id: UInt32) {
        guard !isStopped, !isSuspended, let action = actionsByID[id] else { return }
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
