import Foundation

@main
enum PlaybackPolicyTests {
    static func main() {
        let updaterKey = Data(repeating: 7, count: 32).base64EncodedString()
        precondition(UpdaterConfiguration.isValid(feedURL: "https://updates.example.com/appcast.xml", publicKey: updaterKey))
        precondition(!UpdaterConfiguration.isValid(feedURL: "https://updates.example.com/appcast.xml", publicKey: nil))
        precondition(!UpdaterConfiguration.isValid(feedURL: "http://updates.example.com/appcast.xml", publicKey: updaterKey))
        precondition(!UpdaterConfiguration.isValid(feedURL: "https://updates.example.com/appcast.xml", publicKey: Data(repeating: 7, count: 31).base64EncodedString()))

        precondition(SafariUserAgent.make(installedVersion: "27.0.1") == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0.1 Safari/605.1.15")
        precondition(SafariUserAgent.make(installedVersion: nil).contains("Version/17.6 Safari/605.1.15"))
        precondition(SafariUserAgent.make(installedVersion: "27beta.1").contains("Version/17.6 Safari/605.1.15"))
        precondition(SafariUserAgent.make(installedVersion: "27..1").contains("Version/17.6 Safari/605.1.15"))

        precondition(PlaybackPolicy.isNetflixOrigin(protocol: "https", host: "www.netflix.com", port: 0))
        precondition(PlaybackPolicy.isNetflixOrigin(protocol: "https", host: "netflix.com", port: 443))
        precondition(!PlaybackPolicy.isNetflixOrigin(protocol: "https", host: "www.netflix.com", port: 8443))
        precondition(!PlaybackPolicy.isNetflixOrigin(protocol: "http", host: "www.netflix.com", port: 0))
        precondition(!PlaybackPolicy.isNetflixOrigin(protocol: "https", host: "notnetflix.com", port: 0))
        precondition(!PlaybackPolicy.isNetflixOrigin(protocol: "https", host: "netflix.com.attacker.example", port: 0))

        precondition(PlaybackPolicy.isNetflix(URL(string: "https://www.netflix.com/watch/123")))
        precondition(PlaybackPolicy.isNetflix(URL(string: "https://NETFLIX.COM/")))
        precondition(!PlaybackPolicy.isNetflix(URL(string: "http://netflix.com/watch/123")))
        precondition(!PlaybackPolicy.isNetflix(URL(string: "https://netflix.com:8443/watch/123")))
        precondition(!PlaybackPolicy.isNetflix(URL(string: "https://notnetflix.com/watch/123")))
        precondition(!PlaybackPolicy.isNetflix(URL(string: "https://netflix.com.attacker.example/watch/123")))
        precondition(!PlaybackPolicy.isNetflix(nil))

        precondition(PlaybackPolicy.isWatching(URL(string: "https://www.netflix.com/watch/123?trackId=1")))
        precondition(!PlaybackPolicy.isWatching(URL(string: "https://www.netflix.com/browse")))
        precondition(!PlaybackPolicy.isWatching(URL(string: "https://example.com/watch/123")))

        precondition(PlaybackPolicy.keepInApp(URL(string: "https://assets.nflxvideo.net/segment")!))
        precondition(PlaybackPolicy.keepInApp(URL(string: "https://www.google.com/recaptcha")!))
        precondition(!PlaybackPolicy.keepInApp(URL(string: "http://netflix.com/")!))
        precondition(!PlaybackPolicy.keepInApp(URL(string: "https://netflix.com:8443/")!))
        precondition(!PlaybackPolicy.keepInApp(URL(string: "https://netflix.com.attacker.example/")!))

        precondition(shouldRecover())
        precondition(shouldRecover(readyState: 1))
        precondition(shouldRecover(videoPresent: false, readyState: -1))
        precondition(!shouldRecover(videoPresent: false, readyState: -1, paused: true))
        precondition(!shouldRecover(hasStartedPlayback: true))
        precondition(!shouldRecover(retryAttempted: true))
        precondition(!shouldRecover(currentPath: "/watch/456"))
        precondition(!shouldRecover(expectedPath: "/browse", currentPath: "/browse"))
        precondition(!shouldRecover(expectedPath: "/watchfoo/123", currentPath: "/watchfoo/123"))
        precondition(!shouldRecover(paused: true))
        precondition(!shouldRecover(readyState: 2))
        precondition(!shouldRecover(readyState: 4))
        precondition(!shouldRecover(readyState: -1))
        precondition(!shouldRecover(ended: true))
        precondition(!shouldRecover(hasError: true))
        precondition(!shouldRecover(editing: true))

        print("Passed: updater signing configuration, Safari UA version resolution, Netflix origin/routing, and first-play recovery guards.")
    }

    private static func shouldRecover(hasStartedPlayback: Bool = false, retryAttempted: Bool = false,
                                      expectedPath: String = "/watch/123", currentPath: String = "/watch/123",
                                      videoPresent: Bool = true, readyState: Int = 0, paused: Bool = false,
                                      ended: Bool = false, hasError: Bool = false, editing: Bool = false) -> Bool {
        FirstPlaybackRecoveryPolicy.shouldReload(hasStartedPlayback: hasStartedPlayback,
            retryAttempted: retryAttempted, expectedWatchPath: expectedPath, currentWatchPath: currentPath,
            videoPresent: videoPresent, readyState: readyState, paused: paused, ended: ended,
            hasError: hasError, editing: editing)
    }
}
