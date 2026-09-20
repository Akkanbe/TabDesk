import ApplicationServices
import Foundation

/// 他アプリのウィンドウ 1 枚を指す AX 要素のラッパー。
///
/// AXUIElement は不変のハンドルで、AX API はどのスレッドからでも呼べる(AeroSpace 等の実績)。
/// pid ごとに並列で一括移動したいので @unchecked Sendable にしている。
public struct AXWindow: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public let pid: pid_t
    /// 公開AX参照に対応する実行時ID。OSの窓番号ではなく、保存もしない。
    public let windowID: WindowReferenceID
    private let session: AXProcessSession

    public init(element: AXUIElement, pid: pid_t) throws {
        let session = try AXWindowReferenceStore.shared.session(for: pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard try AXAttributes.string(element, kAXRoleAttribute) == kAXWindowRole else {
            throw AXCallError(operation: "window role", code: .illegalArgument)
        }
        guard AXWindowReferenceStore.shared.isCurrent(session) else {
            throw AXCallError(operation: "process session", code: .invalidUIElement)
        }
        self.windowID = try AXWindowReferenceStore.shared.referenceID(for: element, in: session)
        self.session = session
        self.element = element
        self.pid = pid
    }

    private func requireCurrentSession() throws {
        guard AXWindowReferenceStore.shared.isCurrent(session),
              AXWindowReferenceStore.shared.element(for: windowID, in: session) != nil else {
            throw AXCallError(operation: "process session", code: .invalidUIElement)
        }
    }

    public func retireReference() {
        AXWindowReferenceStore.shared.forget(windowID, in: session)
    }

    /// 無効な参照と、窓自体の消滅は同義ではない。呼び手は登録を削除せず未復元に戻す。
    public func referenceStatus() -> WindowReferenceStatus {
        if AXWindowReferenceStore.shared.hasEnded(session) { return .invalidated }
        let roleError: AXError
        do {
            let role = try AXAttributes.string(element, kAXRoleAttribute)
            return role == kAXWindowRole ? .usable : .unknown
        } catch let error as AXCallError {
            roleError = error.code
        } catch { return .unknown }
        guard roleError == .invalidUIElement else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let list = try? AXAttributes.elements(app, kAXWindowsAttribute) else { return .unknown }
        if list.contains(where: { CFEqual($0, element) }) { return .unknown }
        for candidate in list {
            AXUIElementSetMessagingTimeout(candidate, 0.5)
            guard (try? AXAttributes.string(candidate, kAXRoleAttribute)) == kAXWindowRole else { return .unknown }
        }
        return WindowReferenceStatus.evaluate(roleError: roleError, presentInCompleteList: false)
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

    /// 読み取り失敗を「最小化されていない」と扱いたくない操作で使う。
    public var minimizationState: Bool? {
        try? AXAttributes.bool(element, kAXMinimizedAttribute)
    }

    public var isMinimized: Bool { minimizationState ?? false }

    /// 公開APIの位置変更可否。全画面という状態そのものの推測には使わない。
    /// true = 操作保留、false = 位置変更可能、nil = 取得失敗。
    public var layoutSuspension: Bool? {
        do { try requireCurrentSession() } catch { return nil }
        return WindowLayoutAccess.read(element).suspension
    }

    public var isLayoutSuspended: Bool {
        layoutSuspension ?? true
    }

    /// AX 座標系(主画面左上原点・y 下向き)での frame。要素が無効なら throw。
    public func frame() throws -> CGRect {
        try requireCurrentSession()
        let p = try AXAttributes.point(element, kAXPositionAttribute)
        let s = try AXAttributes.size(element, kAXSizeAttribute)
        return CGRect(origin: p, size: s)
    }

    // MARK: - 書き込み

    public func setPosition(_ p: CGPoint) throws {
        try requireCurrentSession()
        try WindowLayoutAccess.read(element).requireMovable()
        try AXAttributes.set(element, kAXPositionAttribute, AXAttributes.wrap(p))
    }

    public func setSize(_ s: CGSize) throws {
        try requireCurrentSession()
        // 全画面中にサイズだけ書き込み可能と返すアプリでも、配置操作を途中から始めない。
        try WindowLayoutAccess.read(element).requireMovable()
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
        // 最後の書き込み中に操作不可へ移行した場合、到達値を正常な保存位置に採用させない。
        try WindowLayoutAccess.read(element).requireMovable()
        return try frame()
    }

    public func raise() throws {
        try requireCurrentSession()
        try WindowLayoutAccess.read(element).requireMovable()
        try AXAttributes.perform(element, action: kAXRaiseAction)
    }

    /// この要素への AX 呼び出しのタイムアウト(秒)。
    /// 無応答アプリが全体を巻き込まないよう短めに設定する。
    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
