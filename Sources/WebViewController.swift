import Cocoa
import WebKit

private final class NativeAudioMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: NativeAudioBridge?
    init(_ bridge: NativeAudioBridge?) { self.bridge = bridge }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              PlaybackPolicy.isNetflixOrigin(protocol: origin.protocol, host: origin.host, port: origin.port),
              AppConfiguration.nativeAudioEnabled,
              let body = message.body as? [String: Any], let bridge else {
            replyHandler(nil, "Native audio bridge unavailable")
            return
        }
        do { replyHandler(try bridge.handle(body), nil) }
        catch {
            replyHandler(nil, "MacflixNativeAudio:\(NativeAudioBridge.failureCategory(for: error))")
        }
    }
}

private final class PlaybackMessageHandler: NSObject, WKScriptMessageHandler {
    var onPlaybackState: ((Bool, Bool, Bool) -> Void)?
    var onPlaybackFailure: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              PlaybackPolicy.isNetflixOrigin(protocol: origin.protocol, host: origin.host, port: origin.port),
              let body = message.body as? [String: Any] else { return }
        if body["playbackFailed"] as? Bool == true { onPlaybackFailure?(); return }
        guard let watching = body["watching"] as? Bool else { return }
        onPlaybackState?(watching, body["playing"] as? Bool == true, body["started"] as? Bool == true)
    }
}

final class WebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var nativeAudioBridge: NativeAudioBridge?
    private var nativeAudioHandler: NativeAudioMessageHandler?
    private let playbackHandler = PlaybackMessageHandler()
    private var audioTimer: Timer?
    private var audioReportInProgress = false
    private var audioStatusShowRequested = false
    private var audioStatusSheetPresented = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var playbackActivity: NSObjectProtocol?
    private var recoveryAttempts = 0
    private var diagnosticsWatchPath: String?
    private var firstPlaybackRecoveryTimer: Timer?
    private var firstPlaybackRecoveryPath: String?
    private var firstPlaybackRecoverySuppressed = false

    private let firstPlaybackStartedKey = "macflix.hasStartedPlayback"
    private let firstPlaybackRetryKey = "macflix.firstPlaybackRecoveryAttempted"

    override func loadView() {
        if AppConfiguration.nativeAudioEnabled {
            do { nativeAudioBridge = try NativeAudioBridge() }
            catch { NSLog("Macflix native audio unavailable; WebKit playback remains enabled: %@", String(describing: error)) }
        }

        let config = makeConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.customUserAgent = AppConfiguration.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.wantsLayer = true
        playbackHandler.onPlaybackState = { [weak self] watching, playing, started in
            guard let self else { return }
            self.setPlaying(watching && playing)
            self.updateFirstPlaybackRecovery(watching: watching, started: watching && started)
            self.inspectTitleIfNeeded(watching: watching)
        }
        playbackHandler.onPlaybackFailure = { [weak self] in self?.showPlaybackFailure() }

        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        let bar = NSView()
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor.black.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Macflix")
        title.textColor = .secondaryLabelColor; title.font = .systemFont(ofSize: 11, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(title)
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar); root.addSubview(webView)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor), bar.heightAnchor.constraint(equalToConstant: 24),
            title.centerXAnchor.constraint(equalTo: bar.centerXAnchor), title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor), webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor), webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSleepWakeObservers()
        audioTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, PlaybackPolicy.isWatching(self.webView.url) else { return }
            self.writeAudioReport()
        }
        goHome()
    }

    deinit {
        audioTimer?.invalidate()
        cancelFirstPlaybackRecovery()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        nativeAudioBridge?.stop()
        endPlaybackActivity()
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: AppConfiguration.profileID)
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let content = WKUserContentController()
        content.add(self.playbackHandler, name: "playback")
        nativeAudioHandler = NativeAudioMessageHandler(nativeAudioBridge)
        content.addScriptMessageHandler(nativeAudioHandler!, contentWorld: .page, name: "nativeAudio")
        addScript("Playback", to: content, world: .page)
        if AppConfiguration.requestAtmos { addScript("MultichannelAudio", to: content, world: .page) }
        if AppConfiguration.nativeAudioEnabled { addScript("NativeAudioBridge", to: content, world: .page) }
        config.userContentController = content
        return config
    }

    private func installScripts() {
        let content = webView?.configuration.userContentController
        guard let content else { return }
        content.removeAllUserScripts()
        addScript("Playback", to: content, world: .page)
        if AppConfiguration.requestAtmos { addScript("MultichannelAudio", to: content, world: .page) }
        if AppConfiguration.nativeAudioEnabled { addScript("NativeAudioBridge", to: content, world: .page) }
    }

    private func addScript(_ name: String, to controller: WKUserContentController, world: WKContentWorld) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Macflix resource unavailable: %@.js", name); return
        }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    func refreshAudioScripts() {
        if AppConfiguration.nativeAudioEnabled {
            if nativeAudioBridge == nil {
                do {
                    nativeAudioBridge = try NativeAudioBridge()
                    nativeAudioHandler?.bridge = nativeAudioBridge
                } catch { NSLog("Macflix native audio unavailable; WebKit playback remains enabled: %@", String(describing: error)) }
            }
        } else {
            nativeAudioBridge?.stop()
            nativeAudioBridge = nil
            nativeAudioHandler?.bridge = nil
        }
        installScripts()
        webView.reload()
    }

    @objc func reload() { webView.reload() }
    @objc func goHome() { webView.load(URLRequest(url: AppConfiguration.homeURL, timeoutInterval: 30)) }

    func showAudioStatus() {
        if audioReportInProgress {
            if !audioStatusSheetPresented { audioStatusShowRequested = true }
            return
        }
        writeAudioReport(show: true)
    }

    private func writeAudioReport(show: Bool = false) {
        guard !audioReportInProgress, PlaybackPolicy.isNetflix(webView.url) else { return }
        guard let url = Bundle.main.url(forResource: "AudioDiagnostics", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { return }
        audioReportInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.audioReportInProgress = false }
            var report: String
            do {
                let result = try await self.webView.callAsyncJavaScript("return await (" + script + ")(preferAtmos, nativeBridgeEnabled)",
                    arguments: ["preferAtmos": AppConfiguration.requestAtmos, "nativeBridgeEnabled": AppConfiguration.nativeAudioEnabled],
                    in: nil, contentWorld: .page)
                report = result as? String ?? "Audio status unavailable"
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Macflix", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try report.write(to: folder.appendingPathComponent("audio-status.json"), atomically: true, encoding: .utf8)
            } catch { report = "Audio status could not be collected or saved. Reload and try again." }
            guard show || self.audioStatusShowRequested else { return }
            self.audioStatusShowRequested = false
            let alert = NSAlert(); alert.messageText = "Macflix Audio Status"; alert.informativeText = report
            if let window = self.view.window {
                self.audioStatusSheetPresented = true
                _ = await alert.beginSheetModal(for: window)
                self.audioStatusSheetPresented = false
            }
        }
    }

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.pauseForSleep() }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeAfterWake() }
    }

    private func pauseForSleep() {
        firstPlaybackRecoverySuppressed = true
        cancelFirstPlaybackRecovery()
        nativeAudioBridge?.stop()
        setPlaying(false)
        webView.evaluateJavaScript("window.macflixPlayback?.pause() ?? document.querySelector('video')?.pause()", completionHandler: nil)
    }

    private func resumeAfterWake() {
        if webView.url == nil { goHome() }
    }

    private func setPlaying(_ value: Bool) {
        if value {
            if playbackActivity == nil {
                playbackActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Macflix Playback Active")
            }
        } else { endPlaybackActivity() }
    }

    private func updateFirstPlaybackRecovery(watching: Bool, started: Bool) {
        let defaults = UserDefaults.standard
        if started {
            defaults.set(true, forKey: firstPlaybackStartedKey)
            cancelFirstPlaybackRecovery()
            return
        }
        guard !firstPlaybackRecoverySuppressed,
              !defaults.bool(forKey: firstPlaybackStartedKey),
              !defaults.bool(forKey: firstPlaybackRetryKey),
              watching, let url = webView.url, PlaybackPolicy.isWatching(url) else {
            cancelFirstPlaybackRecovery()
            return
        }

        let path = url.path
        guard firstPlaybackRecoveryPath != path else { return }
        cancelFirstPlaybackRecovery()
        firstPlaybackRecoveryPath = path
        firstPlaybackRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.checkFirstPlaybackStartup(path: path)
        }
    }

    private func checkFirstPlaybackStartup(path: String) {
        firstPlaybackRecoveryTimer = nil
        guard firstPlaybackRecoveryPath == path,
              let url = webView.url, PlaybackPolicy.isWatching(url), url.path == path else { return }
        let script = """
        (() => {
          const videos = Array.from(document.querySelectorAll('video'));
          const video = videos.find(item => !item.paused && !item.ended) || videos[0] || null;
          const active = document.activeElement;
          return {
            path: location.pathname,
            videoPresent: !!video,
            readyState: video ? video.readyState : -1,
            paused: video ? video.paused : false,
            ended: video ? video.ended : false,
            hasError: !!(video && video.error),
            editing: !!active && (['INPUT', 'TEXTAREA', 'SELECT'].includes(active.tagName) || active.isContentEditable)
          };
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, error == nil, self.firstPlaybackRecoveryPath == path,
                  let currentURL = self.webView.url, PlaybackPolicy.isWatching(currentURL), currentURL.path == path,
                  let state = result as? [String: Any],
                  let currentPath = state["path"] as? String,
                  let videoPresent = state["videoPresent"] as? Bool,
                  let readyState = state["readyState"] as? Int else { return }
            let defaults = UserDefaults.standard
            guard FirstPlaybackRecoveryPolicy.shouldReload(
                hasStartedPlayback: defaults.bool(forKey: self.firstPlaybackStartedKey),
                retryAttempted: defaults.bool(forKey: self.firstPlaybackRetryKey),
                expectedWatchPath: path, currentWatchPath: currentPath,
                videoPresent: videoPresent, readyState: readyState,
                paused: state["paused"] as? Bool == true,
                ended: state["ended"] as? Bool == true,
                hasError: state["hasError"] as? Bool == true,
                editing: state["editing"] as? Bool == true) else { return }

            defaults.set(true, forKey: self.firstPlaybackRetryKey)
            self.cancelFirstPlaybackRecovery()
            self.webView.reload()
        }
    }

    private func cancelFirstPlaybackRecovery() {
        firstPlaybackRecoveryTimer?.invalidate()
        firstPlaybackRecoveryTimer = nil
        firstPlaybackRecoveryPath = nil
    }

    private func inspectTitleIfNeeded(watching: Bool) {
        guard watching, let url = webView.url, PlaybackPolicy.isWatching(url) else {
            if !watching { diagnosticsWatchPath = nil }
            return
        }
        guard diagnosticsWatchPath != url.path else { return }
        guard !audioReportInProgress else { return }
        diagnosticsWatchPath = url.path
        writeAudioReport()
    }

    private func showPlaybackFailure() {
        let alert = NSAlert()
        alert.messageText = "Macflix could not start playback"
        alert.informativeText = "Use Netflix's on-screen Play button to resume, then try the keyboard shortcut again."
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    private func endPlaybackActivity() {
        if let playbackActivity { ProcessInfo.processInfo.endActivity(playbackActivity); self.playbackActivity = nil }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.targetFrame, target.isMainFrame else { decisionHandler(.allow); return }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if !PlaybackPolicy.isWatching(url) || url.path != firstPlaybackRecoveryPath {
            cancelFirstPlaybackRecovery()
        }
        if ["about", "blob", "data", "javascript"].contains(url.scheme?.lowercased() ?? "") { decisionHandler(.allow); return }
        if PlaybackPolicy.keepInApp(url) { nativeAudioBridge?.stop(); decisionHandler(.allow); return }
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
        else { decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if PlaybackPolicy.keepInApp(url) { webView.load(action.request) }
        else if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recoveryAttempts = 0
        setPlaying(false)
        updateFirstPlaybackRecovery(watching: PlaybackPolicy.isWatching(webView.url), started: false)
        inspectTitleIfNeeded(watching: PlaybackPolicy.isWatching(webView.url))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        firstPlaybackRecoverySuppressed = true
        cancelFirstPlaybackRecovery()
        nativeAudioBridge?.stop()
        setPlaying(false)
        guard recoveryAttempts < 5 else {
            let alert = NSAlert(); alert.messageText = "Macflix needs to reload"; alert.informativeText = "The playback page stopped responding. Use Reload Page to try again."; alert.runModal(); return
        }
        recoveryAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + min(pow(2, Double(recoveryAttempts - 1)) * 0.5, 8)) { [weak self] in self?.webView.reload() }
    }
}
