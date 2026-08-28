import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = PoCLogger()
    private lazy var controller = PoCController(logger: logger)
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let mwc = MainWindowController(controller: controller)
        mainWindow = mwc
        mwc.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        logger.log("TabDeskPoC started. log file: \(logger.fileURL.path)")
        controller.status()
        controller.refresh()
    }

    /// tabdeskpoc://... で届いたコマンドを処理する(起動時・起動中どちらも)。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            controller.handle(url: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.prepareForTermination()
        return .terminateNow
    }

    /// Storyboard を使わないので Cmd+Q 等の最低限のメニューを手で作る。
    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TabDeskPoC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }
}
