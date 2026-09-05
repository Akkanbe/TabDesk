import AppKit
import TabDeskCore

/// 画面ごとのサイドバーの生成・破棄・共有配線を一手に持つ(v4 段階 5)。
///
/// FrameWindowController と同じ「seen 集合で冪等 rebuild」パターンだが、パネルは
/// 状態を持つ(改名中・スクロール位置・描画キャッシュ)ので**再利用が必須**。
/// 単一スロットのコールバック(onStateChanged / thumbnails.onUpdated)と
/// 権限バナー用の 1 秒タイマー、画面構成変更 observer は controller が 1 つだけ持つ。
@MainActor
final class SidebarController: NSObject {
    private let manager: WindowManager
    private let logger: FileLogger
    private var panels: [DisplayID: SidebarPanel] = [:]
    private var permissionTimer: Timer?

    init(manager: WindowManager, logger: FileLogger) {
        self.manager = manager
        self.logger = logger
        super.init()
        manager.onStateChanged = { [weak self] _ in self?.render() }
        manager.thumbnails.onUpdated = { [weak self] _ in self?.refreshThumbnailPresentation() }
        manager.addContentAreaObserver { [weak self] in self?.repositionAll() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panels.values.forEach { $0.refreshPermissionBanners() }
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        rebuild()
    }

    var isAnyRenaming: Bool {
        panels.values.contains { $0.isRenaming }
    }

    func panel(for displayID: DisplayID) -> SidebarPanel? {
        panels[displayID]
    }

    /// 接続中のディスプレイに合わせてパネル集合を揃える(冪等。既存パネルは再利用する)。
    func rebuild() {
        var seen = Set<DisplayID>()
        for display in manager.layout.displays {
            seen.insert(display.id)
            if let existing = panels[display.id] {
                existing.refreshAfterLayoutChange()
            } else {
                let panel = SidebarPanel(manager: manager, logger: logger, displayID: display.id)
                panels[display.id] = panel
                panel.orderFrontRegardless()
                logger.log("sidebar: created for display \(display.id)")
            }
        }
        // 切断された画面のパネルは片付ける(タブは state に残り、再接続で戻る)。
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panel.close()
            panels.removeValue(forKey: id)
            logger.log("sidebar: removed for disconnected display \(id)")
        }
    }

    @objc private func screenParametersChanged() {
        rebuild()
    }

    func render() {
        panels.values.forEach { $0.render() }
    }

    /// 幅・折りたたみ変更の再適用後: 全パネルの位置と描画を追従させる
    /// (幅は共有なので、1 画面で変えたら他画面のパネルも動く)。
    private func repositionAll() {
        panels.values.forEach { $0.refreshAfterLayoutChange() }
    }

    func refreshThumbnailPresentation() {
        panels.values.forEach { $0.refreshThumbnailPresentation() }
    }

    func orderFrontAll() {
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    /// 「常に最前面」を全パネルへ反映する(設定は共有)。
    var alwaysOnTop: Bool {
        get { SidebarPanel.alwaysOnTopSetting.value }
        set { panels.values.forEach { $0.alwaysOnTop = newValue } }
    }
}
