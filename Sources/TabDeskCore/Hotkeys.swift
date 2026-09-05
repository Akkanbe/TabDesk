import Foundation

/// グローバルホットキー 1 つ(Carbon の keyCode + modifier ビット)。
/// Carbon に依存しない値として Core に置き、パーサをテスト可能にする。
public struct Hotkey: Sendable, Hashable {
    /// Carbon 仮想キーコード(ANSI 配列)。
    public let keyCode: UInt32
    /// Carbon modifier ビット(cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096)。
    public let modifiers: UInt32
    /// 正規化した表記(ログ・メニュー表示用)。
    public let display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    public static func == (lhs: Hotkey, rhs: Hotkey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        // display はログ用の表記にすぎない。alias や修飾キーの記述順が違っても、
        // Carbon に登録する物理キーが同じなら同一のホットキーとして扱う。
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    public var symbolDisplay: String {
        let symbols: [(UInt32, String)] = [
            (HotkeyParser.controlKey, "⌃"), (HotkeyParser.optionKey, "⌥"),
            (HotkeyParser.shiftKey, "⇧"), (HotkeyParser.cmdKey, "⌘"),
        ]
        let key = HotkeyParser.keyName(for: keyCode) ?? display
        let labels = ["tab": "⇥", "return": "↩", "escape": "⎋", "space": "Space",
                      "left": "←", "right": "→", "up": "↑", "down": "↓",
                      "delete": "⌫", "forwarddelete": "⌦", "home": "↖", "end": "↘",
                      "pageup": "⇞", "pagedown": "⇟"]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + (labels[key] ?? key.uppercased())
    }
}

/// "ctrl+alt+1" のような表記を Hotkey に変換する。
public enum HotkeyParser {
    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case unknownKey(String)
        case unknownModifier(String)
        case missingModifier(String)

        public var description: String {
            switch self {
            case .empty: return "empty hotkey spec"
            case .unknownKey(let k): return "unknown key '\(k)'"
            case .unknownModifier(let m): return "unknown modifier '\(m)'"
            case .missingModifier(let s): return "'\(s)' needs at least one modifier (ctrl/alt/cmd/shift)"
            }
        }
    }

    // Carbon modifier ビット(Carbon.HIToolbox の定数と同値)。
    static let cmdKey: UInt32 = 0x0100
    static let shiftKey: UInt32 = 0x0200
    static let optionKey: UInt32 = 0x0800
    static let controlKey: UInt32 = 0x1000

    private static let modifierNames: [String: UInt32] = [
        "cmd": cmdKey, "command": cmdKey,
        "shift": shiftKey,
        "alt": optionKey, "opt": optionKey, "option": optionKey,
        "ctrl": controlKey, "control": controlKey,
    ]

    /// ANSI 配列の Carbon 仮想キーコード(数字は連番ではない点に注意)。
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        "tab": 48, "space": 49, "return": 36, "escape": 53,
        "delete": 51, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static func keyName(for keyCode: UInt32) -> String? {
        keyCodes.first { $0.value == keyCode }?.key
    }

    /// キー記録と文字列パーサでキー表を共有し、保存後も同じ物理キーへ登録できるようにする。
    public static func specification(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard let key = keyName(for: keyCode) else { return nil }
        let names: [(UInt32, String)] = [
            (controlKey, "ctrl"), (optionKey, "alt"), (shiftKey, "shift"), (cmdKey, "cmd"),
        ]
        let selected = names.filter { modifiers & $0.0 != 0 }.map(\.1)
        guard !selected.isEmpty else { return nil }
        return (selected + [key]).joined(separator: "+")
    }

    public static func parse(_ spec: String) throws -> Hotkey {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { throw ParseError.empty }
        var modifiers: UInt32 = 0
        var names: [String] = []
        for part in parts.dropLast() {
            guard let bit = modifierNames[part] else { throw ParseError.unknownModifier(part) }
            if modifiers & bit == 0 { names.append(part) }
            modifiers |= bit
        }
        guard let keyCode = keyCodes[keyName] else { throw ParseError.unknownKey(keyName) }
        // 修飾キーなしのグローバルホットキーは通常のタイピングを乗っ取るので拒否する。
        guard modifiers != 0 else { throw ParseError.missingModifier(spec) }
        return Hotkey(keyCode: keyCode, modifiers: modifiers, display: (names + [keyName]).joined(separator: "+"))
    }
}

/// ホットキーに割り当てる操作。
public enum HotkeyAction: Sendable, Hashable {
    /// 1 始まり(タブ 1 = 並び順の先頭)。
    case activateTab(Int)
    /// 次のタブへ(末尾なら先頭へ回る)。
    case nextTab
    /// 前のタブへ(先頭なら末尾へ回る)。
    case previousTab
    case registerFocusedWindow
    case toggleEditMode
    /// サイドバーの折りたたみ/展開(v3 段階 3)。
    case toggleSidebar
}

/// hotkeys.json の中身。ユーザーが手で編集できるよう、キーは "ctrl+alt+1" 形式の文字列で持つ。
public struct HotkeyConfig: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case activateTab, nextTab, previousTab, registerFocusedWindow, toggleEditMode, toggleSidebar
    }
    public var activateTab: [String]
    public var nextTab: String?
    public var previousTab: String?
    public var registerFocusedWindow: String?
    public var toggleEditMode: String?
    public var toggleSidebar: String?

    public init(
        activateTab: [String], nextTab: String?, previousTab: String?,
        registerFocusedWindow: String?, toggleEditMode: String?, toggleSidebar: String?
    ) {
        self.activateTab = activateTab
        self.nextTab = nextTab
        self.previousTab = previousTab
        self.registerFocusedWindow = registerFocusedWindow
        self.toggleEditMode = toggleEditMode
        self.toggleSidebar = toggleSidebar
    }

    public static let `default` = HotkeyConfig(
        activateTab: (1...9).map { "ctrl+alt+\($0)" },
        nextTab: "ctrl+tab",
        previousTab: "ctrl+shift+tab",
        registerFocusedWindow: "ctrl+alt+r",
        toggleEditMode: "ctrl+alt+e",
        toggleSidebar: "ctrl+alt+s")

    /// 古い hotkeys.json(キーが無い)は既定値で補い、明示的に null が書かれていれば「割り当てなし」と解釈する。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HotkeyConfig.default
        activateTab = try c.decodeIfPresent([String].self, forKey: .activateTab) ?? d.activateTab
        nextTab = c.contains(.nextTab) ? try c.decodeIfPresent(String.self, forKey: .nextTab) : d.nextTab
        previousTab = c.contains(.previousTab) ? try c.decodeIfPresent(String.self, forKey: .previousTab) : d.previousTab
        registerFocusedWindow = c.contains(.registerFocusedWindow)
            ? try c.decodeIfPresent(String.self, forKey: .registerFocusedWindow) : d.registerFocusedWindow
        toggleEditMode = c.contains(.toggleEditMode)
            ? try c.decodeIfPresent(String.self, forKey: .toggleEditMode) : d.toggleEditMode
        toggleSidebar = c.contains(.toggleSidebar)
            ? try c.decodeIfPresent(String.self, forKey: .toggleSidebar) : d.toggleSidebar
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(activateTab, forKey: .activateTab)
        // nil を省略すると、次回読み込みで「旧設定に存在しないキー」として既定値に戻ってしまう。
        try c.encode(nextTab, forKey: .nextTab)
        try c.encode(previousTab, forKey: .previousTab)
        try c.encode(registerFocusedWindow, forKey: .registerFocusedWindow)
        try c.encode(toggleEditMode, forKey: .toggleEditMode)
        try c.encode(toggleSidebar, forKey: .toggleSidebar)
    }

    /// 設定を (Hotkey, HotkeyAction) の組に解決する。解釈できない項目はエラー文字列として返し、他は生かす。
    public func resolve() -> (bindings: [(Hotkey, HotkeyAction)], errors: [String]) {
        var bindings: [(Hotkey, HotkeyAction)] = []
        var errors: [String] = []
        var seen = Set<Hotkey>()

        func add(_ spec: String, _ action: HotkeyAction, label: String) {
            do {
                let hotkey = try HotkeyParser.parse(spec)
                guard !seen.contains(hotkey) else {
                    errors.append("\(label): '\(spec)' は他の割り当てと重複しています")
                    return
                }
                seen.insert(hotkey)
                bindings.append((hotkey, action))
            } catch {
                errors.append("\(label): \(error)")
            }
        }

        for (index, spec) in activateTab.prefix(9).enumerated() {
            // 空欄のスロットは無効化する。詰めて後続のタブ番号を変えない。
            if spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            add(spec, .activateTab(index + 1), label: "activateTab[\(index)]")
        }
        if let spec = nextTab { add(spec, .nextTab, label: "nextTab") }
        if let spec = previousTab { add(spec, .previousTab, label: "previousTab") }
        if let spec = registerFocusedWindow { add(spec, .registerFocusedWindow, label: "registerFocusedWindow") }
        if let spec = toggleEditMode { add(spec, .toggleEditMode, label: "toggleEditMode") }
        if let spec = toggleSidebar { add(spec, .toggleSidebar, label: "toggleSidebar") }
        return (bindings, errors)
    }

    public static func load(from url: URL) throws -> HotkeyConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HotkeyConfig.self, from: try Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
