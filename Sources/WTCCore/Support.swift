import Foundation

/// 経過時間計測(ミリ秒)。
public struct Stopwatch: Sendable {
    private let start = DispatchTime.now().uptimeNanoseconds

    public init() {}

    public var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

/// ロック付きの可変値。バックグラウンドの並列処理から結果を集めるために使う。
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    public func withValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        withValue { $0 }
    }
}
