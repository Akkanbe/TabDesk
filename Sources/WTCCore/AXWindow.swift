import ApplicationServices
import AXShim
import Foundation

/// 他アプリのウィンドウ 1 枚を指す AX 要素のラッパー。
///
/// AXUIElement は不変のハンドルで、AX API はどのスレッドからでも呼べる(AeroSpace 等の実績)。
/// pid ごとに並列で一括移動したいので @unchecked Sendable にしている。
public struct AXWindow: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public let pid: pid_t
    /// WindowServer が振るセッション内 ID。アプリ再起動をまたいでは安定しない。
    public let windowID: CGWindowID

    /// 私有関数で CGWindowID が取れない要素は管理対象にできないので throw する。
    /// 失敗理由(AXError)は v0 検証項目 2 の判定材料なので握りつぶさない。
    public init(element: AXUIElement, pid: pid_t) throws {
        var wid: CGWindowID = 0
        let err = AXShimGetWindowID(element, &wid)
        guard err == .success else {
            throw AXCallError(operation: "_AXUIElementGetWindow", code: err)
        }
        self.element = element
        self.pid = pid
        self.windowID = wid
    }

    public static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    // MARK: - 読み取り

    public var title: String {
        (try? AXAttributes.string(element, kAXTitleAttribute)) ?? ""
    }

    public var subrole: String? {
        try? AXAttributes.string(element, kAXSubroleAttribute)
    }

    public var isStandard: Bool {
        subrole == kAXStandardWindowSubrole
    }

    public var isMinimized: Bool {
        (try? AXAttributes.bool(element, kAXMinimizedAttribute)) ?? false
    }

    /// AX 座標系(主画面左上原点・y 下向き)での frame。要素が無効なら throw。
    public func frame() throws -> CGRect {
        let p = try AXAttributes.point(element, kAXPositionAttribute)
        let s = try AXAttributes.size(element, kAXSizeAttribute)
        return CGRect(origin: p, size: s)
    }

    // MARK: - 書き込み

    public func setPosition(_ p: CGPoint) throws {
        try AXAttributes.set(element, kAXPositionAttribute, AXAttributes.wrap(p))
    }

    public func setSize(_ s: CGSize) throws {
        try AXAttributes.set(element, kAXSizeAttribute, AXAttributes.wrap(s))
    }

    /// 位置とサイズをまとめて設定する。
    ///
    /// 位置とサイズは別属性で原子的に設定できない。先に位置を動かすと「現サイズでは画面に収まらない」
    /// として OS に位置を丸められることがあるため、サイズ→位置→サイズの順で適用する(Rectangle と同じ手順)。
    /// 戻り値は適用後に読み戻した実際の frame(PoC では要求値との差を記録する)。
    @discardableResult
    public func setFrame(_ r: CGRect) throws -> CGRect {
        try setSize(r.size)
        try setPosition(r.origin)
        try setSize(r.size)
        return try frame()
    }

    public func raise() throws {
        try AXAttributes.perform(element, action: kAXRaiseAction)
    }

    /// この要素への AX 呼び出しのタイムアウト(秒)。
    /// 無応答アプリが全体を巻き込まないよう短めに設定する。
    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
