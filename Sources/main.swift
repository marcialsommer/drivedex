import AppKit
import ServiceManagement
import UserNotifications
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandlerWithReply,
    WKUIDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var window: NSWindow!
    lazy var menuDB = DB()   // read-only use on the main thread for the menu bar
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    let apiQueue = DispatchQueue(label: "drivedex.api", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        if offerMoveToApplications() { return }

        buildMenu()
        buildStatusItem()
        buildWindow()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "launchedBefore") {
            defaults.set(true, forKey: "launchedBefore")
            try? SMAppService.mainApp.register()   // start at login by default
        }

        // When started automatically at login, stay quietly in the menu bar.
        let atLogin = ProcessInfo.processInfo.systemUptime < 240 && defaults.bool(forKey: "shownOnce")
        if atLogin { NSApp.setActivationPolicy(.accessory) } else { showWindow() }
        defaults.set(true, forKey: "shownOnce")

        Scanner.shared.start()

        // Look for app updates shortly after launch and then a few times a day.
        let checkUpdates = {
            DispatchQueue.global(qos: .utility).async {
                Updater.checkInBackgroundIfDue { text in
                    guard Settings.notify else { return }
                    let c = UNMutableNotificationContent()
                    c.title = "DriveDex"
                    c.body = text
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: checkUpdates)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in checkUpdates() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Keep running in the menu bar so new drives still get catalogued.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - UI

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        showWindow()
        webView.evaluateJavaScript("openSettings()", completionHandler: nil)
    }

    @objc func checkForUpdates() {
        showWindow()
        webView.evaluateJavaScript("checkUpdates(true)", completionHandler: nil)
    }

    @objc func focusSearch() {
        showWindow()
        webView.evaluateJavaScript("document.querySelector('#q').focus()", completionHandler: nil)
    }

    @objc func rescanConnected() { Scanner.shared.scanAllConnected(force: true) }

    func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "api")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self   // makes confirm()/alert() in the page show real dialogs
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "DriveDex"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("DriveDexMain")

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self            // rebuilt every time it opens (see menuNeedsUpdate)
        statusItem.menu = menu
        refreshStatusIcon()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusIcon() }
        }
    }

    /// Menu bar icon reflects backup health: plain = fine, orange = needs attention, red = files without backup.
    func refreshStatusIcon() {
        let worst = menuDB.health().map { $0.level }.max() ?? 0
        let name: String, color: NSColor?
        switch worst {
        case 2: name = "externaldrive.badge.xmark"; color = .systemRed
        case 1: name = "externaldrive.badge.exclamationmark"; color = .systemOrange
        default: name = "externaldrive"; color = nil
        }
        var img = NSImage(systemSymbolName: name, accessibilityDescription: "DriveDex")
            ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "DriveDex")
        if let c = color, let colored = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [c])) {
            img = colored
            img?.isTemplate = false
        } else {
            img?.isTemplate = true
        }
        statusItem.button?.image = img
        statusItem.button?.toolTip = worst == 0 ? "DriveDex: everything backed up" : "DriveDex: some backups need attention"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let health = menuDB.health()
        let bad = health.filter { $0.level > 0 }.count
        let head = NSMenuItem(title: health.isEmpty ? "No main drives set up yet"
                              : bad == 0 ? "✓ Everything is backed up" : "\(bad) drive\(bad == 1 ? "" : "s") need\(bad == 1 ? "s" : "") attention",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if !health.isEmpty { menu.addItem(.separator()) }
        for h in health {
            let mark = h.level == 0 ? "✓" : h.level == 1 ? "⚠︎" : "✕"
            let item = NSMenuItem(title: "\(mark)  \(h.name): \(h.text)", action: #selector(openDriveFromMenu(_:)), keyEquivalent: "")
            item.tag = h.id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, sel) in [("Open DriveDex", #selector(showWindow)), ("Rescan Connected Drives", #selector(rescanConnected)),
                             ("Check for Updates…", #selector(checkForUpdates))] {
            menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DriveDex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        refreshStatusIcon()
    }

    @objc func openDriveFromMenu(_ sender: NSMenuItem) {
        showWindow()
        webView.evaluateJavaScript("openDrive(\(sender.tag),'');driveTab='backups';render()", completionHandler: nil)
    }

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DriveDex", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Rescan Connected Drives", action: #selector(rescanConnected), keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DriveDex", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit DriveDex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(focusSearch), keyEquivalent: "f").target = self
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    /// If launched from the disk image (or a quarantined Downloads copy), offer to move into /Applications.
    func offerMoveToApplications() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move DriveDex to your Applications folder?"
        alert.informativeText = "DriveDex needs to live in Applications so it can start automatically and notice when you plug in a drive."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/DriveDex.app")
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return true
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't move DriveDex"
            a.informativeText = "Please drag DriveDex into your Applications folder in Finder, then open it from there.\n\n\(error.localizedDescription)"
            a.runModal()
            return false
        }
    }

    // MARK: - JS bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else {
            replyHandler(nil, "Bad message")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        apiQueue.async {
            let result = Bridge.handle(action, args)
            DispatchQueue.main.async { replyHandler(result, nil) }
        }
    }

    // MARK: - page dialogs (confirm / alert)

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let parts = message.components(separatedBy: "\n\n")
        alert.messageText = parts.first ?? message
        if parts.count > 1 { alert.informativeText = parts.dropFirst().joined(separator: "\n\n") }
        alert.addButton(withTitle: message.hasPrefix("Forget") ? "Forget" : "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    // MARK: - notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.showWindow() }
        completionHandler()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
