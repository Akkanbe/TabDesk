import AppKit
import ApplicationServices
import Foundation
import Darwin

/// 保存用の登録UUIDやCGWindowIDとは独立した、その実行中だけの参照ID。
public struct WindowReferenceID: Hashable, Sendable, CustomStringConvertible {
    private let value: UUID
    public init() { value = UUID() }
    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.value = value
    }
    public var description: String { value.uuidString }
}

/// PID再利用や、終了後に遅れて届いた通知を現在のプロセスと混同しないための世代。
public struct AXProcessSession: Hashable, Sendable {
    public let pid: pid_t
    private let generation = UUID()
    fileprivate init(pid: pid_t) { self.pid = pid }
}

/// 公開APIだけでAX参照の同一性を管理する。同期アクセスをロックで直列化する。
/// 読み取り失敗や一覧からの欠落では削除しない。終了・破棄を確認した呼び手が明示的に破棄する。
/// 窓としての適格性は呼び手が検証する。この型自体は属性を使った同一性の推測を行わない。
public final class AXWindowReferenceStore: @unchecked Sendable {
    public static let shared = AXWindowReferenceStore()
    private let lock = NSRecursiveLock()
    public enum StoreError: Error, Equatable {
        case processUnavailable
        case staleSession
        case processMismatch
        case cannotReadProcess(Int32)
    }

    private struct Entry {
        let id: WindowReferenceID
        let element: AXUIElement
    }

    private struct Process {
        let session: AXProcessSession
        var launchDate: Date?
        var entries: [Entry] = []
    }

    private var processes: [pid_t: Process] = [:]

    private let processStartDate: @Sendable (pid_t) -> Date?

    public init() { processStartDate = Self.readProcessStartDate }

    init(processStartDate: @escaping @Sendable (pid_t) -> Date?) {
        self.processStartDate = processStartDate
    }

    static func readProcessStartDate(_ pid: pid_t) -> Date? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        if let date = app.launchDate { return date }
        // Dockerなど、LaunchServicesに起動日時がないアプリもPID再利用を検出する。
        return readKernelStartDate(pid)
    }

    static func readKernelStartDate(_ pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// 起動日時を世代に含め、同じPIDで再起動したアプリの参照を再利用しない。
    public func session(for pid: pid_t) throws -> AXProcessSession {
        lock.lock(); defer { lock.unlock() }
        guard let date = processStartDate(pid), processStartDate(pid) == date else {
            throw StoreError.processUnavailable
        }
        if let process = processes[pid], process.launchDate == date { return process.session }
        let session = beginProcess(pid: pid)
        processes[pid]?.launchDate = date
        return session
    }

    /// 遅延した終了通知が同じPIDの新しい世代を破棄しないよう、起動日時も照合する。
    public func endProcess(pid: pid_t, launchDate: Date?) {
        lock.lock(); defer { lock.unlock() }
        guard let launchDate, processes[pid]?.launchDate == launchDate else { return }
        processes.removeValue(forKey: pid)
    }

    public func isCurrent(_ session: AXProcessSession) -> Bool {
        (try? self.session(for: session.pid)) == session
    }

    public func hasEnded(_ session: AXProcessSession) -> Bool {
        lock.lock()
        let current = processes[session.pid]
        lock.unlock()
        if let current, current.session != session { return true }
        if let date = current?.launchDate, let actual = processStartDate(session.pid) { return date != actual }
        guard let app = NSRunningApplication(processIdentifier: session.pid) else {
            return kill(session.pid, 0) != 0 && errno == ESRCH
        }
        return app.isTerminated
    }

    /// 呼び手が新しいプロセスの開始を確認したときだけ呼ぶ。毎回の列挙では呼ばない。
    public func beginProcess(pid: pid_t) -> AXProcessSession {
        lock.lock(); defer { lock.unlock() }
        let session = AXProcessSession(pid: pid)
        processes[pid] = Process(session: session)
        return session
    }

    public func endProcess(_ session: AXProcessSession) {
        lock.lock(); defer { lock.unlock() }
        guard processes[session.pid]?.session == session else { return }
        processes.removeValue(forKey: session.pid)
    }

    public func referenceID(for element: AXUIElement, in session: AXProcessSession) throws -> WindowReferenceID {
        lock.lock(); defer { lock.unlock() }
        guard processes[session.pid]?.session == session else { throw StoreError.staleSession }
        if let id = existingID(for: element, in: session) { return id }
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else { throw StoreError.cannotReadProcess(result.rawValue) }
        guard pid == session.pid else { throw StoreError.processMismatch }
        let id = WindowReferenceID()
        processes[session.pid]?.entries.append(Entry(id: id, element: element))
        return id
    }

    /// destroyed通知では失効した要素の属性を問い合わせず、保持済みの参照と比較する。
    public func existingID(for element: AXUIElement, in session: AXProcessSession) -> WindowReferenceID? {
        lock.lock(); defer { lock.unlock() }
        guard let process = processes[session.pid], process.session == session else { return nil }
        return process.entries.first { CFEqual($0.element, element) }?.id
    }

    public func element(for id: WindowReferenceID, in session: AXProcessSession) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        guard let process = processes[session.pid], process.session == session else { return nil }
        return process.entries.first { $0.id == id }?.element
    }

    public func forget(_ id: WindowReferenceID, in session: AXProcessSession) {
        lock.lock(); defer { lock.unlock() }
        guard processes[session.pid]?.session == session else { return }
        processes[session.pid]?.entries.removeAll { $0.id == id }
    }
}
