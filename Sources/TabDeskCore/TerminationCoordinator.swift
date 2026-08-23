import Foundation

/// アプリ終了時のクリーンアップを「完了」か「期限」のどちらか早い方で 1 回だけ返事する。
///
/// AX 操作はキャンセルに協調しないので、TaskGroup の cancelAll では止まらず期限が効かない。
/// そこで cleanup と期限タイマーを独立に走らせ、先に終わった方が `reply` を呼ぶ(2 回目は無視)。
/// AppKit に依存しないのでユニットテストできる。
@MainActor
public final class TerminationCoordinator {
    public private(set) var isTerminating = false
    public private(set) var replyCount = 0

    private let deadline: Duration
    private let cleanup: @MainActor () async -> Void
    private let reply: @MainActor (String) -> Void

    public init(
        deadline: Duration,
        cleanup: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (String) -> Void
    ) {
        self.deadline = deadline
        self.cleanup = cleanup
        self.reply = reply
    }

    /// `applicationShouldTerminate` から呼ぶ。2 回目以降の要求は無視する(進行中の cleanup を待たせる)。
    public func requestTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        let deadline = self.deadline
        Task { [weak self] in
            try? await Task.sleep(for: deadline)
            self?.replyOnce("deadline reached; cleanup still running, some windows may remain parked")
        }
        Task { [weak self] in
            guard let self else { return }
            await self.cleanup()
            self.replyOnce("cleanup finished")
        }
    }

    private func replyOnce(_ reason: String) {
        guard replyCount == 0 else { return }
        replyCount += 1
        reply(reason)
    }
}
