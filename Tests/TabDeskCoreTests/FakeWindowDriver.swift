import CoreGraphics
import Foundation
@testable import TabDeskCore

/// テスト用の偽ドライバ。ウィンドウを辞書で持ち、最小サイズ制約・消滅・遅延を再現できる。
final class FakeWindowDriver: WindowDriver, @unchecked Sendable {
    struct Window {
        var frame: CGRect
        var minSize: CGSize = .zero
        var alive = true
        /// 操作 1 回あたりの擬似 IPC 遅延(秒)。pid 並列の検証用。
        var delay: TimeInterval = 0
        /// raise だけ失敗するアプリ(setFrame は成功)。
        var raiseFails = false
        /// 「適用はされたがタイムアウトで失敗扱いになった」を模す: 変更を反映したうえで throw する。
        var throwAfterApply = false
        /// 書き込み(setFrame / setPosition / raise)だけ失敗し、読み取りは通る(無応答アプリに近い)。
        var failWrites = false
        /// ネイティブフルスクリーン中。書き込みは黙って飲み込まれ、frame は変わらない(実機の挙動に最も近い)。
        var fullscreen = false
        /// AXFullScreen の読み取りだけ失敗する(frame は読める)。忙しいアプリの属性タイムアウトを模す。
        var fullscreenReadFails = false
    }

    private let lock = NSLock()
    private var windows: [CGWindowID: Window] = [:]
    private(set) var calls: [String] = []
    private var active = 0
    private(set) var maxConcurrent = 0

    func add(_ id: CGWindowID, frame: CGRect, minSize: CGSize = .zero, delay: TimeInterval = 0) {
        lock.withLock { windows[id] = Window(frame: frame, minSize: minSize, delay: delay) }
    }

    func kill(_ id: CGWindowID) {
        lock.withLock { windows[id]?.alive = false }
    }

    func revive(_ id: CGWindowID) {
        lock.withLock { windows[id]?.alive = true }
    }

    func setRaiseFails(_ id: CGWindowID, _ value: Bool = true) {
        lock.withLock { windows[id]?.raiseFails = value }
    }

    func setThrowAfterApply(_ id: CGWindowID, _ value: Bool = true) {
        lock.withLock { windows[id]?.throwAfterApply = value }
    }

    func setFailWrites(_ id: CGWindowID, _ value: Bool = true) {
        lock.withLock { windows[id]?.failWrites = value }
    }

    func setFullscreen(_ id: CGWindowID, _ value: Bool = true) {
        lock.withLock { windows[id]?.fullscreen = value }
    }

    func setFullscreenReadFails(_ id: CGWindowID, _ value: Bool = true) {
        lock.withLock { windows[id]?.fullscreenReadFails = value }
    }

    struct SimulatedTimeout: Error {}

    func setMinSize(_ size: CGSize, of id: CGWindowID) {
        lock.withLock { windows[id]?.minSize = size }
    }

    /// ユーザー操作やアプリ自身の移動を模す(エンジンを経由しない frame 変更)。
    func moveExternally(_ id: CGWindowID, to frame: CGRect) {
        lock.withLock { windows[id]?.frame = frame }
    }

    func currentFrame(_ id: CGWindowID) -> CGRect? {
        lock.withLock { windows[id]?.frame }
    }

    func callCount(_ prefix: String) -> Int {
        lock.withLock { calls.filter { $0.hasPrefix(prefix) }.count }
    }

    func totalCallCount() -> Int {
        lock.withLock { calls.count }
    }

    private func withWindow<T>(_ id: CGWindowID, _ name: String, _ body: (inout Window) throws -> T) throws -> T {
        let delay: TimeInterval = lock.withLock {
            calls.append("\(name):\(id)")
            active += 1
            maxConcurrent = max(maxConcurrent, active)
            return windows[id]?.delay ?? 0
        }
        defer { lock.withLock { active -= 1 } }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return try lock.withLock {
            guard var w = windows[id], w.alive else { throw WindowDriverError.unknownWindow(id) }
            if w.failWrites, name != "frame" { throw SimulatedTimeout() }
            let result = try body(&w)
            windows[id] = w
            if w.throwAfterApply, name != "frame" { throw SimulatedTimeout() }
            return result
        }
    }

    func frame(of windowID: CGWindowID) throws -> CGRect {
        try withWindow(windowID, "frame") { $0.frame }
    }

    @discardableResult
    func setFrame(_ frame: CGRect, of windowID: CGWindowID) throws -> CGRect {
        try withWindow(windowID, "setFrame") { w in
            // フルスクリーン中は書き込みが黙って飲み込まれる(throw せず frame も変わらない)。
            // 修正前のエンジンはこれで「3 回試行 → フルスクリーン寸法を採用」に陥っていた。
            if w.fullscreen { return w.frame }
            // 実アプリの最小サイズ制約を模す。位置は要求どおり、サイズだけクランプされる。
            w.frame = CGRect(
                origin: frame.origin,
                size: CGSize(width: max(frame.width, w.minSize.width), height: max(frame.height, w.minSize.height)))
            return w.frame
        }
    }

    func setPosition(_ point: CGPoint, of windowID: CGWindowID) throws {
        try withWindow(windowID, "setPosition") { w in
            if w.fullscreen { return }
            w.frame.origin = point
        }
    }

    func isFullscreen(of windowID: CGWindowID) throws -> Bool? {
        try withWindow(windowID, "isFullscreen") { $0.fullscreenReadFails ? nil : $0.fullscreen }
    }

    func raise(_ windowID: CGWindowID) throws {
        try withWindow(windowID, "raise") { w in
            if w.raiseFails { throw SimulatedTimeout() }
        }
    }
}
