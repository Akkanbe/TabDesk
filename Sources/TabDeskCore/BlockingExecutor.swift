import Foundation

/// ブロッキングする処理(AX の同期 IPC)を GCD のグローバルキューで実行して await する。
///
/// Swift Concurrency の協調スレッドプールは CPU コア数ぶんしかないので、そこで IPC をブロックさせると
/// 無応答アプリが数個あるだけで他の処理まで詰まる。GCD に逃がせばメインアクターも他タスクも止まらない。
public struct BlockingExecutor: Sendable {
    public init() {}

    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    public func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: body())
            }
        }
    }
}
