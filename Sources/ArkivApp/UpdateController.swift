import AppKit
import Sparkle

/// Small menu-facing seam lets lifecycle tests run without network or preferences writes.
protocol UpdaterMenuDriver: AnyObject {
    var checkTarget: AnyObject { get }
    var checkAction: Selector { get }
    var automaticallyChecksForUpdates: Bool { get set }
}

private final class SparkleMenuDriver: UpdaterMenuDriver {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var checkTarget: AnyObject { controller }
    var checkAction: Selector { #selector(SPUStandardUpdaterController.checkForUpdates(_:)) }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// Sparkle owns transport, signature verification, installation and relaunch.
/// Menus may exist well before an interactive session starts the updater.
final class UpdateController: NSObject, NSMenuItemValidation {
    private let publicKey: () -> String?
    private let makeDriver: () -> UpdaterMenuDriver
    private var driver: UpdaterMenuDriver?
    private var checkItems: [NSMenuItem] = []
    private var automaticItems: [NSMenuItem] = []

    override convenience init() {
        self.init(publicKey: { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String },
                  makeDriver: { SparkleMenuDriver() })
    }
    init(publicKey: @escaping () -> String?, makeDriver: @escaping () -> UpdaterMenuDriver) {
        self.publicKey = publicKey; self.makeDriver = makeDriver
        super.init()
    }

    func start() {
        guard driver == nil else { refreshMenuItems(); return }
        guard let key = publicKey(), Data(base64Encoded: key)?.count == 32 else {
            refreshMenuItems(); return
        }
        driver = makeDriver()
        refreshMenuItems()
    }

    func addMenuItems(to menu: NSMenu) {
        checkItems.append(menu.addItem(withTitle: "Check for Updates…", action: nil, keyEquivalent: ""))
        let automatic = menu.addItem(withTitle: "Automatically Check for Updates", action: #selector(toggleAutomatic(_:)), keyEquivalent: "")
        automatic.target = self
        automaticItems.append(automatic)
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        for item in checkItems {
            item.target = driver?.checkTarget ?? self
            item.action = driver?.checkAction ?? #selector(unconfigured(_:))
            // Sparkle performs its own menu validation (for example during an update).
            item.isEnabled = true
        }
        for item in automaticItems {
            item.isEnabled = driver != nil
            item.state = driver?.automaticallyChecksForUpdates == true ? .on : .off
        }
    }

    @objc private func unconfigured(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Updates are not configured in this build"
        alert.informativeText = "Install a development build containing Arkiv’s update signing public key. See the updater setup documentation in the Arkiv repository."
        alert.runModal()
    }

    @objc private func toggleAutomatic(_ sender: Any?) {
        guard let driver else { return }
        driver.automaticallyChecksForUpdates.toggle()
        refreshMenuItems()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomatic(_:)) {
            menuItem.state = driver?.automaticallyChecksForUpdates == true ? .on : .off
            return driver != nil
        }
        return true
    }
}
