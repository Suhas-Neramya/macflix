import Foundation

@main
enum PlaybackPolicyTests {
    static func main() {
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

        print("Passed: Netflix playback routing and HTTPS in-app host boundaries.")
    }
}
