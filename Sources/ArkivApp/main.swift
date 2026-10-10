import AppKit
import Sparkle
import FinderSync
import ArkivFinderIntegration
import ArkivCore
import ArkivPresentation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updates: UpdateController
    private let launchArguments: [String]
    private let presentFinderSetup: (() -> Void)?
    override convenience init() {
        self.init(updates: UpdateController(), launchArguments: CommandLine.arguments)
    }
    init(updates: UpdateController, launchArguments: [String], presentFinderSetup: (() -> Void)? = nil) {
        self.updates = updates; self.launchArguments = launchArguments; self.presentFinderSetup = presentFinderSetup
        super.init()
    }
    private let finderDeliveryDiagnostic = FinderDeliveryDiagnostic.fromArguments()
    private lazy var finderSetup = FinderSetupWindowController()
    private let creation = ArchiveCreationController()
    private var handledLaunchRequest = false
    private var startedInteractiveSession = false
    private var windows: [BrowserWindowController] = []
    private lazy var finderServices = FinderServiceProvider { [weak self] url in
        self?.open(url)
        self?.finderDeliveryDiagnostic?.record(.open)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = finderServices
    }
    static func shouldShowInitialBrowser(arguments: [String], handledRequest: Bool) -> Bool {
        !arguments.contains("--finder-action") && !handledRequest
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        if Self.shouldShowInitialBrowser(arguments: launchArguments, handledRequest: handledLaunchRequest) {
            if windows.isEmpty { newWindow(nil) }
            NSApp.activate(ignoringOtherApps: true)
            beginInteractiveSession()
        }
    }
    private func beginInteractiveSession() {
        guard !startedInteractiveSession, finderDeliveryDiagnostic == nil else { return }
        startedInteractiveSession = true
        updates.start()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let presentFinderSetup = self.presentFinderSetup { presentFinderSetup() }
            else { self.finderSetup.presentIfNeeded() }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        finderSetup.refresh()
        if !windows.isEmpty { beginInteractiveSession() }
    }
    @objc func newWindow(_ sender: Any?) { makeWindow().showWindow(nil) }
    private func makeWindow() -> BrowserWindowController {
        let controller = BrowserWindowController()
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        controller.onOpen = { [weak self, weak controller] in self?.openArchive(controller) }
        return controller
    }
    @objc func openArchive(_ sender: Any?) {
        let preferred = (sender as? BrowserWindowController)?.windowID
            ?? windows.first(where: { $0.window === NSApp.keyWindow })?.windowID
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Open an archive to browse its contents."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url, preferred: preferred) }
    }
    private func open(_ url: URL, preferred: UUID? = nil) {
        let preferred = preferred ?? windows.first(where: { $0.window === NSApp.keyWindow })?.windowID
        let id = BrowserPresentation.window(for: url, preferred: preferred, among: windows.map(\.routingState))
        let controller = windows.first(where: { $0.windowID == id }) ?? makeWindow()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        beginInteractiveSession()
        if controller.archiveURL == nil { controller.load(url) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let controller = windows.last { controller.showWindow(nil) }
            else { newWindow(nil) }
        }
        beginInteractiveSession()
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunchRequest = true
        for url in urls {
            if url.scheme == FinderHandoff.scheme && url.host == "create" {
                do {
                    let request = try CreationHandoff(url: url)
                    if let diagnostic = finderDeliveryDiagnostic {
                        diagnostic.recordCommand(request.command.rawValue, browserWindows: windows.count)
                    } else if request.command == .zip || request.command == .sevenZip {
                        try creation.compress(request.sources, format: request.command == .sevenZip ? .sevenZip : .zip)
                    }
                    else { creation.present(request.sources, parent: windows.first(where: { $0.window === NSApp.keyWindow })?.window, encrypted: request.command == .password) }
                } catch { NSAlert(error: error).runModal() }
            } else if url.scheme == FinderHandoff.scheme {
                do {
                    if let diagnostic = finderDeliveryDiagnostic {
                        try finderServices.receive(url) { request in
                            if request.action == .open { try self.finderServices.perform(request) }
                            else { diagnostic.recordCommand(request.action.rawValue, browserWindows: self.windows.count) } // Read-only CI; never extract.
                        }
                    } else { try finderServices.receive(url) }
                }
                catch { NSAlert(error: error).runModal() }
            } else if url.isFileURL { open(url) }
        }
    }
    @objc private func createArchive(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add"; panel.message = "Choose files and folders for a new ZIP archive."
        guard panel.runModal() == .OK else { return }
        creation.present(panel.urls, parent: windows.first(where: { $0.window === NSApp.keyWindow })?.window)
    }

    @objc private func showFinderIntegration(_ sender: Any?) {
        finderSetup.showSetup()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finderServices.isBusy || creation.isBusy || windows.contains(where: \.isBusy) {
            let alert = NSAlert()
            alert.messageText = "An archive operation is still running"
            alert.informativeText = "Cancel it and wait for cleanup before quitting."
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    @objc func testArchiveFile(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "Test"; panel.message = "Select a ZIP, 7z, or TAR archive to test, including a damaged archive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try finderServices.perform(FinderRequest(action: .test, urls: [url])) }
        catch { NSAlert(error: error).runModal() }
    }
    private func buildMenus() {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "About Arkiv", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        updates.addMenuItems(to: application)
        let finder = application.addItem(withTitle: "Finder Integration…", action: #selector(showFinderIntegration(_:)), keyEquivalent: "")
        finder.target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Arkiv", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Quit Arkiv", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        let new = file.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n"); new.target = self
        let create = file.addItem(withTitle: "Create Archive…", action: #selector(createArchive(_:)), keyEquivalent: "N"); create.target = self
        let open = file.addItem(withTitle: "Open Archive…", action: #selector(openArchive(_:)), keyEquivalent: "o"); open.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Extract Selected…", action: #selector(BrowserWindowController.extractSelected(_:)), keyEquivalent: "e")
        file.addItem(withTitle: "Extract All…", action: #selector(BrowserWindowController.extractAll(_:)), keyEquivalent: "E")
        file.addItem(withTitle: "Test Archive", action: #selector(BrowserWindowController.testArchive(_:)), keyEquivalent: "t")
        let testFile = file.addItem(withTitle: "Test Archive File…", action: #selector(testArchiveFile(_:)), keyEquivalent: "T"); testFile.target = self
        file.addItem(withTitle: "Archive Info", action: #selector(BrowserWindowController.showInfo(_:)), keyEquivalent: "i")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Find", action: #selector(BrowserWindowController.focusSearch(_:)), keyEquivalent: "f")
        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        go.addItem(withTitle: "Parent Folder", action: #selector(BrowserWindowController.goUp(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        for (title, menu) in [("Arkiv", application), ("File", file), ("Edit", edit), ("Go", go), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu; main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}

// Packaging smoke test exercises dyld and the embedded Sparkle framework without starting UI.
if CommandLine.arguments.contains("--verify-updater-bundle") {
    let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework").resolvingSymlinksInPath()
    let loaded = Bundle(for: SPUStandardUpdaterController.self).bundleURL.resolvingSymlinksInPath()
    guard loaded == expected else {
        fputs("Sparkle was not loaded from the packaged app\n", stderr)
        exit(1)
    }
    let seven = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libArkivSeven.dylib").resolvingSymlinksInPath()
    guard SevenZipBackend.loadedLibraryURL.resolvingSymlinksInPath() == seven else {
        fputs("7z engine was not loaded from the packaged app\n", stderr)
        exit(1)
    }
    print("Loaded embedded Sparkle framework and 7z engine")
    exit(0)
}

NSWindow.allowsAutomaticWindowTabbing = false
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
