import Foundation

@main
enum NativeAudioBridgeTests {
    static func main() {
        let domain = "NetflixDev.NativeAudioBridge"
        let cases = [
            ("Encrypted audio is unsupported", "protected-audio"),
            ("Clear E-AC-3 JOC audio is required", "unsupported-audio"),
            ("Native audio could not decode the sample", "decode-error"),
            ("Native audio listener failed", "listener-failed"),
            ("Stale session", "stale-session"),
            ("Invalid playback clock", "invalid-message"),
            ("MP4 fragment timestamp discontinuity", "parser-error"),
            ("Unexpected failure details", "native-error")
        ]
        for (message, expected) in cases {
            let error = NSError(domain: domain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            precondition(NativeAudioBridge.failureCategory(for: error) == expected, "Unexpected category for \(message)")
        }
        let foreign = NSError(domain: "Other", code: 1, userInfo: [NSLocalizedDescriptionKey: "private detail"])
        precondition(NativeAudioBridge.failureCategory(for: foreign) == "native-error")
        print("Passed: native audio failures map to fixed, sanitized categories.")
    }
}
