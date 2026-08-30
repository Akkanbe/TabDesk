import AppKit
import ScreenCaptureKit
import TabDeskCore

/// タブ切替時に「離れたタブ」の代表窓を静止画で撮影して保持する(v3 段階 5)。
///
/// ScreenCaptureKit を import するのはこのファイルだけ。`SCScreenshotManager` のワンショット
/// キャプチャなので常時ストリームは張らない(メニューバーの収録インジケータも出ない)。
/// `SCContentFilter(desktopIndependentWindow:)` は退避中・隠れた窓もそのまま撮れるため、
/// 切替完了後(退避後)の撮影でタイミング競合は起きない。
@MainActor
final class ThumbnailStore {
    /// 既定 OFF: 画面収録権限のプロンプト(と macOS 仕様の月次再承認)は、
    /// ユーザーが機能を有効にしたときだけ出す(docs/05_v3_design.md)。
    static let enabledSetting = PersistedToggle(key: "TabThumbnailsEnabled", defaultValue: false)
    /// 撮影の縮小幅(pt)。サイドバー行より少し大きめに撮って Retina でぼやけないようにする。
    private static let targetWidth: CGFloat = 448

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// tab.id キー。行ビューは state 変更のたびに作り直されるので、キャッシュはここに置く。
    private(set) var images: [UUID: NSImage] = [:]
    var onUpdated: (@MainActor (UUID) -> Void)?
    private var captureTasks: [UUID: Task<Void, Never>] = [:]
    /// 失敗ログは 1 回だけ(切替のたびに同じ失敗を書かない)。
    private var loggedFailure = false
    private let logger: FileLogger

    init(logger: FileLogger) {
        self.logger = logger
    }

    /// タブの代表窓を非同期で撮影する(同じタブの前回の撮影が残っていれば置き換える)。
    func capture(tabID: UUID, windowID: CGWindowID) {
        guard Self.enabledSetting.value, Self.hasPermission else { return }
        captureTasks[tabID]?.cancel()
        captureTasks[tabID] = Task { [weak self] in
            await self?.performCapture(tabID: tabID, windowID: windowID)
        }
    }

    func remove(tabID: UUID) {
        captureTasks[tabID]?.cancel()
        captureTasks[tabID] = nil
        images[tabID] = nil
    }

    private func performCapture(tabID: UUID, windowID: CGWindowID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return }
            let size = scWindow.frame.size
            guard size.width > 0, size.height > 0 else { return }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = min(1, Self.targetWidth / size.width)
            config.width = Int(size.width * scale * 2)  // 2x = Retina ぶん
            config.height = Int(size.height * scale * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard !Task.isCancelled else { return }
            images[tabID] = NSImage(
                cgImage: image, size: NSSize(width: size.width * scale, height: size.height * scale))
            onUpdated?(tabID)
        } catch {
            // 権限剥奪・窓の消滅などは静かに劣化する(古いサムネイルを残す)。
            if !loggedFailure {
                loggedFailure = true
                logger.log("thumbnail: capture failed (以後この失敗は記録しない): \(error)")
            }
        }
    }
}
