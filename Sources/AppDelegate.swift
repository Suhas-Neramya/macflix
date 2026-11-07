import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.register(defaults: [
            "macflix.requestMultichannelAudio": true,
            "macflix.nativeAudioBridgeEnabled": true
        ])
        setupMenu()
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil); windowController?.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu()
        app.addItem(withTitle: "About Macflix", action: #selector(showAbout), keyEquivalent: "")
        app.addItem(NSMenuItem.separator())
        app.addItem(withTitle: "Hide Macflix", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Macflix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; menu.addItem(appItem)

        let fileItem = NSMenuItem(); let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file; menu.addItem(fileItem)

        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)

        let viewItem = NSMenuItem(); let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload Page", action: #selector(reload), keyEquivalent: "r")
        view.addItem(withTitle: "Go to Netflix Home", action: #selector(home), keyEquivalent: "H")
        let full = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]; view.addItem(full)
        viewItem.submenu = view; menu.addItem(viewItem)

        let audioItem = NSMenuItem(); let audio = NSMenu(title: "Audio")
        let prefer = NSMenuItem(title: "Request and Prefer Available Atmos (Experimental)", action: #selector(toggleAtmos(_:)), keyEquivalent: "")
        prefer.state = AppConfiguration.requestAtmos ? .on : .off; audio.addItem(prefer)
        let native = NSMenuItem(title: "Native Atmos Audio Bridge (Experimental)", action: #selector(toggleNative(_:)), keyEquivalent: "")
        native.state = AppConfiguration.nativeAudioEnabled ? .on : .off; audio.addItem(native)
        audio.addItem(withTitle: "Audio Status…", action: #selector(showStatus), keyEquivalent: "")
        audioItem.submenu = audio; menu.addItem(audioItem)

        let winItem = NSMenuItem(); let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win; menu.addItem(winItem)
        NSApp.mainMenu = menu
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(string: "Developed by Suhas Chandrasekara\n\nIndependent app; not affiliated with Netflix, Inc.")
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Macflix", .applicationVersion: "0.2.1", .credits: credits])
    }
    @objc private func reload() { windowController?.reload() }
    @objc private func home() { windowController?.goHome() }
    @objc private func showStatus() { windowController?.showAudioStatus() }
    @objc private func toggleAtmos(_ sender: NSMenuItem) { let value = !AppConfiguration.requestAtmos; AppConfiguration.requestAtmos = value; sender.state = value ? .on : .off; windowController?.refreshAudioScripts() }
    @objc private func toggleNative(_ sender: NSMenuItem) { let value = !AppConfiguration.nativeAudioEnabled; AppConfiguration.nativeAudioEnabled = value; sender.state = value ? .on : .off; windowController?.refreshAudioScripts() }
}

enum AppConfiguration {
    static let homeURL = URL(string: "https://www.netflix.com")!
    static let profileID = UUID(uuidString: "187EA74C-BD22-44B4-9B75-53A9212AC89D")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    static var requestAtmos: Bool { get { UserDefaults.standard.bool(forKey: "macflix.requestMultichannelAudio") } set { UserDefaults.standard.set(newValue, forKey: "macflix.requestMultichannelAudio") } }
    static var nativeAudioEnabled: Bool { get { UserDefaults.standard.bool(forKey: "macflix.nativeAudioBridgeEnabled") } set { UserDefaults.standard.set(newValue, forKey: "macflix.nativeAudioBridgeEnabled") } }
}
