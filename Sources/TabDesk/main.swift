import AppKit

// AppKit は applicationDidFinishLaunching 等で起きた ObjC 例外を黙って握りつぶし、処理途中で止まったまま
// プロセスが生き続ける(UI が出ないのに起動しているように見える)。開発中はクラッシュさせて気付けるようにする。
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
NSSetUncaughtExceptionHandler { exception in
    let line = "UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "") \(exception.callStackSymbols.prefix(8))\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TabDesk/tabdesk.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// LSUIElement = true なので Dock には出ない(メニューバー常駐)。
app.setActivationPolicy(.accessory)
app.run()
