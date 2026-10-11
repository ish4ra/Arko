import AppKit
import ArkivCore
import ArkivPresentation

final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    let windowID = UUID()
    private var pendingURL: URL?
    var archiveURL: URL? { snapshot?.url ?? pendingURL }
    var routingState: ArchiveWindowState {
        ArchiveWindowState(id: windowID, archiveURL: archiveURL,
            isAvailable: !isBusy && window?.attachedSheet == nil)
    }
    private(set) var isBusy = false
    private let table = ArchiveTableView()
    private let search = NSSearchField()
    private let pathLabel = NSTextField(labelWithString: "Open an archive to begin")
    private let status = NSTextField(labelWithString: "ZIP and TAR • Browse before extracting")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let emptyView = NSView()
    private let browserView = NSView()
    private let footer = NSStackView()
    private let emptyOpenButton = NSButton(title: "Open Archive…", target: nil, action: nil)
    private let noResults = NSTextField(labelWithString: "")
    private var navigationButtons: [NSButton] = []
    private var snapshot: ArchiveSnapshot?
    private var zipAdditionAvailable = false
    private let modificationFeedback: (Result<URL, Error>) -> Void
    private var index: ArchiveIndex?
    private var rows: [BrowserRow] = []
    private var currentPath = ""
    private var back: [String] = []
    private var forward: [String] = []
    private var cancellation: ArchiveCancellation?
    private let engine = LibArchiveEngine()
    private let worker = DispatchQueue(label: "xyz.isharalakshan.arkiv.archive", qos: .userInitiated)

    init(modificationFeedback: @escaping (Result<URL, Error>) -> Void = { ExtractionFeedback.completed($0) }) {
        self.modificationFeedback = modificationFeedback
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Arkiv"
        window.minSize = NSSize(width: 640, height: 360)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = makeContent()
        let toolbar = NSToolbar(identifier: "ArkivBrowser")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func makeContent() -> NSView {
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain
        table.backgroundColor = .textBackgroundColor
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(activateRow(_:))
        table.setAccessibilityLabel("Archive contents")
        for (id, title, width) in [("name", "Name", 500.0), ("size", "Size", 110.0), ("type", "Kind", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? 180 : 80
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            column.headerCell.alignment = id == "size" ? .right : .left
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let menu = NSMenu()
        let extract = menu.addItem(withTitle: "Extract Selected…", action: #selector(extractSelected(_:)), keyEquivalent: "")
        extract.target = self
        let copy = menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(.separator())
        for (title, action) in [("Add Files…", #selector(addFiles(_:))), ("Add Folder…", #selector(addFolder(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        search.placeholderString = "Search archive"
        search.controlSize = .small
        search.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        search.delegate = self
        search.setAccessibilityLabel("Search archive paths")
        search.toolTip = "Search all paths in this archive (⌘F)"
        search.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setAccessibilityLabel("Current folder")
        let definitions: [(String, String, Selector)] = [
            ("Back (⌘[)", "chevron.left", #selector(goBack(_:))),
            ("Forward (⌘])", "chevron.right", #selector(goForward(_:))),
            ("Up to parent folder (⌘↑)", "arrow.up", #selector(goUp(_:)))
        ]
        navigationButtons = definitions.map { title, symbol, action in
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
            button.bezelStyle = .texturedRounded; button.controlSize = .small
            button.toolTip = title; button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            return button
        }
        let navigation = NSStackView(views: navigationButtons + [pathLabel, search])
        navigation.spacing = 6; navigation.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        let separator = NSBox(); separator.boxType = .separator
        let browser = NSStackView(views: [navigation, separator, scroll])
        browser.orientation = .vertical; browser.alignment = .leading; browser.spacing = 0
        for child in [navigation, separator, scroll] { child.widthAnchor.constraint(equalTo: browser.widthAnchor).isActive = true }
        pin(browser, inside: browserView)
        noResults.font = .systemFont(ofSize: 13); noResults.textColor = .secondaryLabelColor
        noResults.translatesAutoresizingMaskIntoConstraints = false
        browserView.addSubview(noResults)
        NSLayoutConstraint.activate([noResults.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            noResults.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Arkiv")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let description = NSTextField(labelWithString: "Browse an archive and choose what to extract.")
        description.font = .systemFont(ofSize: 13); description.textColor = .secondaryLabelColor
        emptyOpenButton.target = self; emptyOpenButton.action = #selector(openArchive(_:))
        emptyOpenButton.bezelStyle = .rounded
        emptyOpenButton.toolTip = "Choose an archive to browse (⌘O)"
        let hint = NSTextField(labelWithString: "⌘O to open an archive")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let welcome = NSStackView(views: [icon, title, description, emptyOpenButton, hint])
        welcome.orientation = .vertical; welcome.alignment = .centerX; welcome.spacing = 10
        welcome.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(welcome)
        NSLayoutConstraint.activate([welcome.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor)])
        let body = NSView()
        pin(browserView, inside: body); pin(emptyView, inside: body)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); cancelButton.isHidden = true
        cancelButton.bezelStyle = .rounded; cancelButton.controlSize = .small
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(status); footer.addArrangedSubview(spinner); footer.addArrangedSubview(cancelButton)
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let content = NSStackView(views: [body, footer])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 0
        for child in [body, footer] { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        updateControls()
        return content
    }
    private func pin(_ child: NSView, inside parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    @objc func openArchive(_ sender: Any?) { onOpen?() }
    private func updateControls() {
        emptyView.isHidden = snapshot != nil
        browserView.isHidden = snapshot == nil
        footer.isHidden = snapshot == nil && !isBusy
        emptyOpenButton.isEnabled = !isBusy
        for button in navigationButtons {
            button.isEnabled = validateMenuItem(NSMenuItem(title: "", action: button.action, keyEquivalent: ""))
        }
        window?.toolbar?.validateVisibleItems()
    }
    func load(_ url: URL, password: String? = nil) {
        guard !isBusy else { return }
        pendingURL = url
        let token = begin("Reading archive…")
        worker.async { [self] in
            let result = Result { try self.engine.inspect(url, cancellation: token, password: password) }
            let canAdd = (try? result.get()).map { ArchiveZIPUpdater().canAdd(to: $0) } ?? false
            DispatchQueue.main.async { [self] in
                self.pendingURL = nil
                self.finish()
                switch result {
                case .success(let value):
                    self.snapshot = value; self.index = value.index; self.zipAdditionAvailable = canAdd
                    self.currentPath = ""; self.back = []; self.forward = []
                    self.window?.title = url.lastPathComponent
                    self.window?.representedURL = url
                    self.reload()
                    self.window?.makeFirstResponder(self.table)
                case .failure(let error):
                    if ArchivePasswordPrompt.isPasswordFailure(error) {
                        ArchivePasswordPrompt.ask(archive: url, retry: password != nil, parent: self.window) { [weak self] supplied in
                            if let supplied { self?.load(url, password: supplied) }
                        }
                    } else { self.present(error) }
                }
            }
        }
    }
    private func begin(_ message: String) -> ArchiveCancellation {
        let token = ArchiveCancellation(); cancellation = token
        isBusy = true; search.isEnabled = false
        status.stringValue = message; spinner.startAnimation(nil); cancelButton.isHidden = false
        updateControls()
        return token
    }
    private func finish() {
        isBusy = false; cancellation = nil; search.isEnabled = true
        spinner.stopAnimation(nil); cancelButton.isHidden = true
        updateControls()
    }
    @objc func cancel(_ sender: Any?) { cancellation?.cancel(); status.stringValue = "Cancelling…" }
    @objc func focusSearch(_ sender: Any?) { window?.makeFirstResponder(search) }
    private func selectedPaths() -> Set<String> {
        Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil })
    }
    @objc func testArchive(_ sender: Any?) {
        guard !isBusy, let url = snapshot?.url else { return }
        test(url)
    }
    private func test(_ url: URL, password: String? = nil) {
        let token = begin("Testing archive…")
        worker.async { [self] in
            let throttle = ProgressThrottle()
            let result = Result {
                try engine.test(url, cancellation: token, password: password) { progress in
                    guard throttle.shouldUpdate() else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isBusy else { return }
                        self.status.stringValue = "\(progress.files) entries · \(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file)) tested"
                    }
                }
            }
            DispatchQueue.main.async { [self] in
                finish()
                switch result {
                case .success(let value):
                    status.stringValue = "Test Archive — " + value.state.rawValue
                    let alert = NSAlert(); alert.messageText = status.stringValue; alert.informativeText = value.detail
                    alert.alertStyle = value.state == .ok ? .informational : .warning
                    if let window { alert.beginSheetModal(for: window) }
                case .failure(let error):
                    if ArchivePasswordPrompt.isPasswordFailure(error) {
                        ArchivePasswordPrompt.ask(archive: url, retry: password != nil, parent: window) { [weak self] supplied in
                            if let supplied { self?.test(url, password: supplied) }
                        }
                    } else { present(error) }
                }
            }
        }
    }
    @objc func addFiles(_ sender: Any?) { chooseAdditions(folder: false) }
    @objc func addFolder(_ sender: Any?) { chooseAdditions(folder: true) }
    private var canAddToZIP: Bool {
        guard !isBusy, zipAdditionAvailable, let snapshot else { return false }
        return FileManager.default.isWritableFile(atPath: snapshot.url.path)
            && FileManager.default.isWritableFile(atPath: snapshot.url.deletingLastPathComponent().path)
    }
    private func chooseAdditions(folder: Bool) {
        guard canAddToZIP, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = !folder
        panel.prompt = "Add"
        panel.message = "Add \(folder ? "a folder" : "files") at the archive root. Existing names are never replaced."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addItems(panel.urls)
        }
    }
    /// Shared by both native pickers; all transaction work stays in ArkivCore.
    func addItems(_ urls: [URL]) {
        guard canAddToZIP, !urls.isEmpty, let snapshot else { return }
        let token = begin("Adding to ZIP…")
        worker.async { [self] in
            let throttle = ProgressThrottle()
            let result = Result {
                try ArchiveZIPUpdater().add(sources: urls, to: snapshot, cancellation: token) { progress in
                    guard throttle.shouldUpdate() else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isBusy else { return }
                        self.status.stringValue = "\(progress.files) entries · \(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file)) processed"
                    }
                }
            }
            DispatchQueue.main.async { [self] in
                finish()
                modificationFeedback(result)
                switch result {
                case .success(let url):
                    // Publication is already complete. Refresh failures are read errors,
                    // not a failed transaction and never trigger another success sound.
                    self.snapshot = nil; self.index = nil; self.zipAdditionAvailable = false
                    search.stringValue = ""
                    load(url)
                case .failure(let error): present(error)
                }
            }
        }
    }
    @objc func extractSelected(_ sender: Any?) {
        guard let index else { return }
        let ids = index.entryIDs(for: selectedPaths())
        guard !ids.isEmpty else { return }
        extract(ids)
    }
    @objc func extractAll(_ sender: Any?) { extract(nil) }
    private func extract(_ ids: [Int64]?) {
        guard let snapshot, !isBusy, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "Arkiv creates a new folder here. Existing files are never replaced. Links and special files are rejected."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let parent = panel.url, let self else { return }
            let token = self.begin("Extracting…")
            self.worker.async { [self] in
                // C callbacks run serially on this worker. Throttle main-thread traffic.
                let throttle = ProgressThrottle()
                let result = Result {
                    try self.engine.extract(snapshot, ids: ids, into: parent, cancellation: token) { [weak self] progress in
                        guard throttle.shouldUpdate() else { return }
                        DispatchQueue.main.async {
                            guard let self, self.isBusy else { return }
                            self.status.stringValue = "\(progress.files) entries • \(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file)) extracted"
                        }
                    }
                }
                DispatchQueue.main.async { [self] in
                    self.finish()
                    ExtractionFeedback.completed(result)
                    switch result {
                    case .success(let output):
                        self.status.stringValue = "Extraction complete"
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    case .failure(let error): self.present(error)
                    }
                }
            }
        }
    }
    private func present(_ error: Error) {
        status.stringValue = error.localizedDescription
        if case ArchiveFailure.cancelled = error { return }
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
    private func navigate(_ path: String) {
        guard !isBusy else { return }
        back.append(currentPath); forward.removeAll(); currentPath = path
        search.stringValue = ""; reload(preservingSelection: false)
    }
    @objc func activateRow(_ sender: Any?) {
        guard rows.indices.contains(table.clickedRow), rows[table.clickedRow].isDirectory else { return }
        navigate(rows[table.clickedRow].path)
    }
    @objc func goUp(_ sender: Any?) { if !currentPath.isEmpty { navigate(currentPath.split(separator: "/").dropLast().joined(separator: "/")) } }
    @objc func goBack(_ sender: Any?) {
        guard !isBusy, let path = back.popLast() else { return }
        forward.append(currentPath); currentPath = path; search.stringValue = ""; reload(preservingSelection: false)
    }
    @objc func goForward(_ sender: Any?) {
        guard !isBusy, let path = forward.popLast() else { return }
        back.append(currentPath); currentPath = path; search.stringValue = ""; reload(preservingSelection: false)
    }
    @objc func showInfo(_ sender: Any?) {
        guard let snapshot, let window else { return }
        let alert = NSAlert()
        alert.messageText = snapshot.url.lastPathComponent
        alert.informativeText = "\(snapshot.entries.count) entries\nBackend: \(LibArchiveEngine.version)\n\nExtraction limit: 100,000 entries / 20 GiB. ZIP and 7z creation are available from File → Create Archive. 7z supports AES-256. Add Files/Add Folder are available for supported writable ZIPs. Other modification is unavailable."
        alert.beginSheetModal(for: window)
    }
    @objc func copyPath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedPaths().sorted().joined(separator: "\n"), forType: .string)
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload(preservingSelection: Bool = true) {
        let paths = preservingSelection ? selectedPaths() : []
        rows = search.stringValue.isEmpty ? index?.children(of: currentPath) ?? [] : index?.search(search.stringValue) ?? []
        sortRows()
        pathLabel.stringValue = currentPath.isEmpty ? (snapshot?.url.lastPathComponent ?? "") : "/" + currentPath
        pathLabel.toolTip = (snapshot?.url.lastPathComponent ?? "") + ": /" + currentPath
        table.reloadData()
        table.selectRowIndexes(BrowserPresentation.selection(paths, in: rows), byExtendingSelection: false)
        if !preservingSelection { table.scroll(.zero) }
        noResults.stringValue = search.stringValue.isEmpty ? "This folder is empty" : "No matching entries"
        noResults.isHidden = !rows.isEmpty
        updateStatus(); updateControls()
    }
    private func updateStatus() {
        guard !isBusy, let snapshot else { return }
        var text = "\(rows.count) shown · \(snapshot.entries.count) archive entries"
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        if !selected.isEmpty {
            text += " · \(selected.count) selected"
            if let bytes = BrowserPresentation.selectedSize(selected) {
                text += " (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
            }
        }
        status.stringValue = text
        status.toolTip = text
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus(); window?.toolbar?.validateVisibleItems() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ArchiveCellView ?? ArchiveCellView(column: id.rawValue)
        cell.configure(rows[row], column: id.rawValue, searching: !search.stringValue.isEmpty)
        return cell
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let paths = selectedPaths()
        sortRows(); table.reloadData()
        table.selectRowIndexes(BrowserPresentation.selection(paths, in: rows), byExtendingSelection: false)
        updateStatus()
    }
    private func sortRows() {
        guard let sort = table.sortDescriptors.first else { return }
        rows = BrowserPresentation.sorted(rows, by: sort.key ?? "name", ascending: sort.ascending)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(addFiles(_:)), #selector(addFolder(_:)): return canAddToZIP && window?.attachedSheet == nil
        case #selector(copyPath(_:)), #selector(extractSelected(_:)): return !isBusy && !selectedPaths().isEmpty
        case #selector(testArchive(_:)), #selector(extractAll(_:)), #selector(showInfo(_:)): return !isBusy && snapshot != nil
        case #selector(goUp(_:)): return !isBusy && !currentPath.isEmpty
        case #selector(goBack(_:)): return !isBusy && !back.isEmpty
        case #selector(goForward(_:)): return !isBusy && !forward.isEmpty
        case #selector(focusSearch(_:)): return !isBusy && snapshot != nil
        default: return !isBusy
        }
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let menu = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
        return validateMenuItem(menu)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isBusy { cancel(nil); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("open"), .flexibleSpace, NSToolbarItem.Identifier("extract"), NSToolbarItem.Identifier("all"), NSToolbarItem.Identifier("test"), NSToolbarItem.Identifier("info")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let definitions: [String: (String, String, Selector)] = [
            "open": ("Open Archive", "folder", #selector(openArchive(_:))),
            "extract": ("Extract Selected", "arrow.down.doc", #selector(extractSelected(_:))),
            "all": ("Extract All", "square.and.arrow.down", #selector(extractAll(_:))),
            "test": ("Test Archive", "checkmark.shield", #selector(testArchive(_:))),
            "info": ("Info", "info.circle", #selector(showInfo(_:)))
        ]
        guard let (title, symbol, action) = definitions[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title; item.paletteLabel = title
        let tips = ["open": "Open an archive (⌘O)", "extract": "Extract selected files and folders (⌘E)",
            "all": "Extract the entire archive (⇧⌘E)", "info": "Show archive information (⌘I)"]
        item.toolTip = tips[id.rawValue]
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self; item.action = action
        return item
    }
}
private final class ProgressThrottle: @unchecked Sendable {
    // Called only by a single synchronous engine operation.
    private var last = Date.distantPast
    func shouldUpdate() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.1 else { return false }
        last = now; return true
    }
}
