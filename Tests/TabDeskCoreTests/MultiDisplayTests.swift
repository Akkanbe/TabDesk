import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

// 2 画面構成のフィクスチャ(AX 座標)。主画面 1920×1200(サイドバー 240px を除く)、
// 右隣に外部 2560×1440。displayID は再起動で安定する UUID 文字列の代わりに固定文字列を使う。
private let mainDisplay = DisplayLayout(
    id: "main",
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1200),
    contentArea: CGRect(x: 240, y: 30, width: 1680, height: 1090),
    parkPoint: CGPoint(x: 1919, y: 1199))
private let secondDisplay = DisplayLayout(
    id: "second",
    frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
    contentArea: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
    parkPoint: CGPoint(x: 4479, y: 1439))

private func identity(_ name: String) -> WindowIdentity {
    WindowIdentity(bundleID: "test.\(name)", appName: name, title: name, registeredSize: CGSize(width: 800, height: 600))
}

@MainActor
private func makeEngine() -> (TabEngine, FakeWindowDriver, MutableScreenLayout) {
    let driver = FakeWindowDriver()
    let layout = MutableScreenLayout(displays: [mainDisplay, secondDisplay])
    var config = TabEngine.Configuration()
    config.debounce = .milliseconds(20)
    let engine = TabEngine(driver: driver, layout: layout, configuration: config)
    return (engine, driver, layout)
}

/// マルチディスプレイ(段階 D)の検証。
@MainActor
struct MultiDisplayTests {
    /// 外部ディスプレイの窓は登録しても主ディスプレイへ引き込まれず、所属が記録される。
    @Test func registeringOnSecondaryKeepsWindowThere() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: frame, into: tab.id)
        #expect(managed.displayID == "second")
        #expect(driver.currentFrame(1) == frame, "外部ディスプレイに留まる")
    }

    /// 主ディスプレイの窓は従来どおりサイドバーを避けた領域へ寄せられる。
    @Test func registeringOnPrimaryStillAvoidsSidebar() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"),
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), into: tab.id)
        #expect(managed.displayID == "main")
        #expect(driver.currentFrame(1)?.minX == 240, "サイドバー分だけ右へ寄る")
    }

    /// 退避はその窓のディスプレイの隅へ(画面をまたぐ退避はしない)。
    @Test func parkingUsesOwnDisplayCorner() async throws {
        let (engine, driver, _) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 2400, y: 200, width: 800, height: 600))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("ext"), frame: CGRect(x: 2400, y: 200, width: 800, height: 600), into: a.id)
        driver.add(3, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        try await engine.register(windowID: 3, pid: 300, identity: identity("b"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: b.id)

        try await engine.activate(b.id)
        #expect(driver.currentFrame(1)?.origin == mainDisplay.parkPoint)
        #expect(driver.currentFrame(2)?.origin == secondDisplay.parkPoint, "外部の窓は外部の隅へ")
    }

    /// 「隅にいる」判定は自分のディスプレイの隅 x と比較する。正しく退避済みの窓を reconcile が動かさない。
    @Test func reconcileDoesNotReparkWindowsAtTheirOwnCorner() async throws {
        let (engine, driver, _) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 2400, y: 200, width: 800, height: 600))
        try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: CGRect(x: 2400, y: 200, width: 800, height: 600), into: b.id)
        _ = a
        #expect(driver.currentFrame(1)?.origin == secondDisplay.parkPoint, "非アクティブタブへの登録で外部の隅へ退避")

        let before = driver.callCount("setPosition")
        for _ in 0..<3 {
            await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        }
        #expect(driver.callCount("setPosition") == before, "主ディスプレイの隅 x と比較していれば毎回再退避してしまう")
    }

    /// ディスプレイが切断されたら、その窓は主ディスプレイのコンテンツ領域へ収める(段階 D の消失ポリシー)。
    @Test func disconnectedDisplayFallsBackToPrimary() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)

        layout.change(displays: [mainDisplay])
        await engine.reapplyLayout()

        let current = try #require(driver.currentFrame(1))
        #expect(mainDisplay.contentArea.contains(current), "主ディスプレイの領域内へ移る")
    }

    /// columns はディスプレイごとに独立して等分する(画面をまたいだ 1 本の列にはしない)。
    @Test func columnsTilePerDisplay() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        driver.add(3, frame: CGRect(x: 2400, y: 200, width: 800, height: 600))
        try await engine.register(windowID: 1, pid: 100, identity: identity("m1"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("m2"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 3, pid: 300, identity: identity("ext"), frame: CGRect(x: 2400, y: 200, width: 800, height: 600), into: tab.id)

        try await engine.setTabLayout(tab.id, .columns)

        let area = mainDisplay.contentArea
        let half = area.width / 2
        #expect(driver.currentFrame(1) == CGRect(x: area.minX, y: area.minY, width: half, height: area.height))
        #expect(driver.currentFrame(2) == CGRect(x: area.minX + half, y: area.minY, width: half, height: area.height))
        #expect(driver.currentFrame(3) == secondDisplay.contentArea, "外部側は 1 窓なので外部の全面")
    }

    /// displayID の無い v1 の JSON は nil(= 主ディスプレイ)として読める。
    @Test func decodingV1WindowWithoutDisplayIDDefaultsToNil() throws {
        let json = """
            {"id": "\(UUID().uuidString)", "frame": [[240, 30], [800, 600]], "identity": \
            {"bundleID": "test.a", "appName": "A", "title": "T", "registeredSize": [800, 600]}}
            """
        let window = try JSONDecoder().decode(ManagedWindow.self, from: Data(json.utf8))
        #expect(window.displayID == nil)
    }

    /// displayID は保存・復元される。
    @Test func displayIDRoundTripsThroughCoding() throws {
        let window = ManagedWindow(
            frame: CGRect(x: 2400, y: 200, width: 800, height: 600),
            identity: identity("ext"), windowID: 1, pid: 100, displayID: "second")
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(ManagedWindow.self, from: data)
        #expect(decoded.displayID == "second")
    }
}
