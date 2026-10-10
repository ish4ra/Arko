import AppKit
import XCTest
@testable import ArkivApp

private final class TestUpdaterDriver: NSObject, UpdaterMenuDriver {
    var automaticallyChecksForUpdates = true
    var checks = 0
    var checkTarget: AnyObject { self }
    var checkAction: Selector { #selector(checkForUpdates(_:)) }
    @objc func checkForUpdates(_ sender: Any?) { checks += 1 }
}

final class UpdateControllerTests: XCTestCase {
    // Public-key-shaped test data only; never an update signing private key.
    private let publicKey = Data(repeating: 1, count: 32).base64EncodedString()

    @MainActor
    func testMenuCreatedBeforeStartBecomesLiveWithoutRebuilding() async {
        _ = NSApplication.shared
        let driver = TestUpdaterDriver()
        var starts = 0
        let updates = UpdateController(publicKey: { self.publicKey }, makeDriver: { starts += 1; return driver })
        let menu = NSMenu()
        updates.addMenuItems(to: menu)
        let check = menu.items[0], automatic = menu.items[1]
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(check.target === updates)
        XCTAssertFalse(updates.validateMenuItem(automatic))
        updates.start()
        XCTAssertTrue(menu.items[0] === check)
        XCTAssertTrue(check.target === driver)
        XCTAssertEqual(check.action, driver.checkAction)
        XCTAssertTrue(automatic.isEnabled)
        XCTAssertEqual(automatic.state, .on)
        XCTAssertTrue(NSApp.sendAction(check.action!, to: check.target, from: check))
        XCTAssertEqual(driver.checks, 1)
        XCTAssertTrue(NSApp.sendAction(automatic.action!, to: automatic.target, from: automatic))
        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertEqual(automatic.state, .off)
        driver.automaticallyChecksForUpdates = true
        XCTAssertTrue(updates.validateMenuItem(automatic))
        XCTAssertEqual(automatic.state, .on)
        updates.start()
        XCTAssertEqual(starts, 1, "Interactive reopen must not create another Sparkle controller")
    }

    @MainActor
    func testStartBeforeMenuAndAdditionalMenusUseCurrentDriver() async {
        let driver = TestUpdaterDriver()
        let updates = UpdateController(publicKey: { self.publicKey }, makeDriver: { driver })
        updates.start()
        for _ in 0..<2 {
            let menu = NSMenu(); updates.addMenuItems(to: menu)
            XCTAssertTrue(menu.items[0].target === driver)
            XCTAssertEqual(menu.items[1].state, .on)
        }
    }

    @MainActor
    func testKeylessAndInvalidKeyBuildsStayUnconfigured() async {
        for key in [nil, "", "invalid", Data(repeating: 0, count: 31).base64EncodedString()] as [String?] {
            var starts = 0
            let updates = UpdateController(publicKey: { key }, makeDriver: { starts += 1; return TestUpdaterDriver() })
            let menu = NSMenu(); updates.addMenuItems(to: menu)
            let originalAction = menu.items[0].action
            updates.start()
            XCTAssertEqual(starts, 0)
            XCTAssertTrue(menu.items[0].target === updates)
            XCTAssertEqual(menu.items[0].action, originalAction)
            XCTAssertFalse(menu.items[1].isEnabled)
            XCTAssertEqual(menu.items[1].state, .off)
        }
    }

    @MainActor
    func testInteractiveColdLaunchAndBackgroundLaunchThenReopen() async throws {
        _ = NSApplication.shared
        for background in [false, true] {
            let oldMenu = NSApp.mainMenu
            let oldWindowsMenu = NSApp.windowsMenu
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            let driver = TestUpdaterDriver()
            var starts = 0
            let updates = UpdateController(publicKey: { self.publicKey }, makeDriver: { starts += 1; return driver })
            let delegate = AppDelegate(updates: updates,
                launchArguments: background ? ["Arkiv", "--finder-action"] : ["Arkiv"], presentFinderSetup: {})
            defer {
                NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
                NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindowsMenu
            }
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            let menu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
            let check = try XCTUnwrap(menu.items.first { $0.title == "Check for Updates…" })
            let automatic = try XCTUnwrap(menu.items.first { $0.title == "Automatically Check for Updates" })
            if background {
                XCTAssertEqual(starts, 0)
                XCTAssertTrue(check.target === updates)
                XCTAssertFalse(automatic.isEnabled)
                XCTAssertFalse(NSApp.windows.contains { !before.contains(ObjectIdentifier($0)) && $0.windowController is BrowserWindowController })
                XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            }
            XCTAssertEqual(starts, 1)
            XCTAssertTrue(check.target === driver)
            XCTAssertTrue(automatic.isEnabled)
            XCTAssertEqual(automatic.state, .on)
            XCTAssertTrue(NSApp.sendAction(check.action!, to: check.target, from: check))
            XCTAssertEqual(driver.checks, 1)
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
            XCTAssertEqual(starts, 1)
        }
    }
}
