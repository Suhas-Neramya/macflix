import Cocoa

final class MainWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        // WKWebView handles these in page JavaScript; don't let an unhandled key ring at the window level.
        if event.keyCode == 49 || event.keyCode == 40 { return }
        super.keyDown(with: event)
    }
}

final class MainWindowController: NSWindowController {
    private let browser = WebViewController()

    init() {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = "Macflix"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 480)
        window.contentViewController = browser
        window.center()
        window.setFrameAutosaveName("MacflixWindowPosition")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reload() { browser.reload() }
    func goHome() { browser.goHome() }
    func showAudioStatus() { browser.showAudioStatus() }
    func refreshAudioScripts() { browser.refreshAudioScripts() }
}
