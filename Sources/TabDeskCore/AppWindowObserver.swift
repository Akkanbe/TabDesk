import ApplicationServices
import Foundation

/// 1 アプリ(pid)のウィンドウ移動・リサイズ等の AX 通知を購読する。
///
/// アプリ要素に対して kAXWindowMoved 等を登録すると、そのアプリの全ウィンドウの通知が
/// 「動いたウィンドウ要素」付きで届くので、ウィンドウごとに登録しなくて済む。
@MainActor
public final class AppWindowObserver {
    public typealias Handler = @MainActor (_ notification: String, _ window: AXUIElement) -> Void

    public let pid: pid_t
    private let observer: AXObserver
    private let appElement: AXUIElement
    private let handler: Handler
    private var isValid = true

    /// - Parameter messagingTimeout: 登録(AXObserverAddNotification)は相手アプリへの同期 IPC で、
    ///   無応答アプリだとメインスレッドが止まる。上限をここで切る(秒)。
    public init(pid: pid_t, notifications: [String], messagingTimeout: Float = 1.0, handler: @escaping Handler) throws {
        self.pid = pid
        self.handler = handler
        self.appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var created: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &created)
        guard err == .success, let created else {
            throw AXCallError(operation: "AXObserverCreate(pid \(pid))", code: err)
        }
        self.observer = created

        // C コールバックに self を渡すための生ポインタ。所有権は移さない(unretained)。
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in notifications {
            let addErr = AXObserverAddNotification(created, appElement, name as CFString, refcon)
            guard addErr == .success else {
                throw AXCallError(operation: "AXObserverAddNotification(\(name), pid \(pid))", code: addErr)
            }
        }
        // メインのランループに載せるので、コールバックは必ずメインスレッドで呼ばれる。
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    /// 購読を止める。deinit に頼らず明示的に呼ぶ(呼び忘れても二重解除にはならない)。
    public func invalidate() {
        guard isValid else { return }
        isValid = false
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func dispatch(_ notification: String, _ element: AXUIElement) {
        guard isValid else { return }
        handler(notification, element)
    }
}

/// AXObserver の C コールバック。refcon から AppWindowObserver を復元して転送する。
private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let target = Unmanaged<AppWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    // CFString/AXUIElement は Sendable でないため、String に変換し、要素は nonisolated(unsafe) で渡す。
    // (AXUIElement は不変ハンドルなのでスレッド間で渡しても安全)
    let name = notification as String
    nonisolated(unsafe) let window = element
    // ランループソースをメインに載せているため、ここはメインスレッド。
    MainActor.assumeIsolated {
        target.dispatch(name, window)
    }
}
