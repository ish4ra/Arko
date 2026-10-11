import AppKit
import XCTest
import ArkivCore
@testable import ArkivApp

final class BrowserWindowTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    func testEmptyWindowHasOriginalIdentityAndNoVisibleTable() async {
        await MainActor.run {
            _ = NSApplication.shared
            let controller = BrowserWindowController()
            defer { controller.close() }
            let window = controller.window!
            let views = descendants(window.contentView!)
            XCTAssertEqual(window.tabbingMode, .disallowed)
            XCTAssertNil(controller.archiveURL)
            XCTAssertTrue(controller.routingState.isAvailable)
            let table = views.compactMap { $0 as? NSTableView }.first!
            XCTAssertTrue(table.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
            XCTAssertTrue(table.allowsMultipleSelection)
            XCTAssertEqual(table.tableColumns.map(\.title), ["Name", "Size", "Kind"])
            XCTAssertTrue(views.contains { ($0 as? NSImageView)?.image === NSApp.applicationIconImage })
            let button = views.compactMap { $0 as? NSButton }.first { $0.title == "Open Archive…" }!
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            var requestedOpen = false
            controller.onOpen = { requestedOpen = true }
            button.performClick(nil)
            XCTAssertTrue(requestedOpen)
            let toolbar = window.toolbar!
            XCTAssertEqual(controller.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue),
                ["open", NSToolbarItem.Identifier.flexibleSpace.rawValue, "extract", "all", "test", "info"])
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserWindowController.extractAll(_:)), keyEquivalent: "")))
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserWindowController.testArchive(_:)), keyEquivalent: "")))
        }
    }
    func testExplicitNewWindowRetainsIndependentWindows() async {
        await MainActor.run {
            _ = NSApplication.shared
            let delegate = AppDelegate()
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            delegate.newWindow(nil)
            delegate.newWindow(nil)
            let created = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.windowController is BrowserWindowController }
            defer { created.forEach { $0.close() } }
            XCTAssertEqual(created.count, 2)
            XCTAssertTrue(created.allSatisfy { $0.tabbingMode == .disallowed })
        }
    }
    @MainActor
    func testOpeningArchiveReusesWindowAndSortingKeepsSelectedFolder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("fixture.zip")
        try Data(base64Encoded: "UEsDBBQAAAAAAIBRR12GphA2BQAAAAUAAAAQAAAAZm9sZGVyL2hlbGxvLnR4dGhlbGxvUEsDBBQAAAAAAIBRR10gNVjZBQAAAAUAAAAJAAAAb3RoZXIudHh0b3RoZXJQSwECFAMUAAAAAACAUUddhqYQNgUAAAAFAAAAEAAAAAAAAAAAAAAAgAEAAAAAZm9sZGVyL2hlbGxvLnR4dFBLAQIUAxQAAAAAAIBRR10gNVjZBQAAAAUAAAAJAAAAAAAAAAAAAACAATMAAABvdGhlci50eHRQSwUGAAAAAAIAAgB1AAAAXwAAAAAA")!.write(to: archive)
        let delegate = AppDelegate()
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        delegate.newWindow(nil)
        let window = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.windowController is BrowserWindowController })
        let controller = try XCTUnwrap(window.windowController as? BrowserWindowController)
        defer { controller.cancel(nil); controller.close() }
        delegate.application(NSApp, open: [archive, archive])
        XCTAssertEqual(controller.archiveURL, archive)
        XCTAssertTrue(controller.isBusy)
        for _ in 0..<200 {
            if !controller.isBusy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(controller.isBusy, "Archive loading should finish within five seconds")
        XCTAssertEqual(window.representedURL, archive)
        delegate.application(NSApp, open: [archive])
        XCTAssertEqual(NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.windowController is BrowserWindowController }.count, 1)
        let table = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTableView }.first)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(table.numberOfRows, 2)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        XCTAssertEqual(table.selectedRow, 1, "Selection must stay on the folder after its row moves")
        let search = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "folder"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 1)
    }
    @MainActor
    func testZIPAdditionRefreshesBrowserAndSoundsOnce() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let added = root.appendingPathComponent("追加 🐘.txt")
        try Data("original".utf8).write(to: original)
        try Data("added".utf8).write(to: added)
        let archive = try ArchiveCreator().create(ArchiveCreationRequest(sources: [original], destination: root, name: "Example"),
            cancellation: ArchiveCancellation(), progress: { _ in })
        var sounds = 0
        let controller = BrowserWindowController(modificationFeedback: { result in
            ExtractionFeedback.completed(result, play: { sounds += 1 })
        })
        defer { controller.close() }
        let addFiles = NSMenuItem(title: "", action: #selector(BrowserWindowController.addFiles(_:)), keyEquivalent: "")
        let addFolder = NSMenuItem(title: "", action: #selector(BrowserWindowController.addFolder(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(addFiles))
        controller.load(archive)
        for _ in 0..<400 {
            if !controller.isBusy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.validateMenuItem(addFiles))
        XCTAssertTrue(controller.validateMenuItem(addFolder))
        controller.addItems([added])
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.validateMenuItem(addFiles))
        for _ in 0..<400 {
            if !controller.isBusy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(sounds, 1)
        let table = try XCTUnwrap(descendants(controller.window!.contentView!).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(controller.archiveURL?.standardizedFileURL, archive.standardizedFileURL)
        let bytes = try Data(contentsOf: archive)
        let another = root.appendingPathComponent("cancelled.txt")
        try Data(repeating: 65, count: 1_000_000).write(to: another)
        controller.addItems([another]); controller.cancel(nil)
        for _ in 0..<400 {
            if !controller.isBusy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(sounds, 1)
        let seven = try ArchiveCreator().create(ArchiveCreationRequest(sources: [original], destination: root, name: "ReadOnly", format: .sevenZip),
            cancellation: ArchiveCancellation(), progress: { _ in })
        let disguised = root.appendingPathComponent("NotActuallyZIP.zip")
        try FileManager.default.moveItem(at: seven, to: disguised)
        controller.load(disguised)
        for _ in 0..<400 {
            if !controller.isBusy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.validateMenuItem(addFiles), "A .zip extension must not grant write support to 7z")
        XCTAssertFalse(controller.validateMenuItem(addFolder))
    }

}
