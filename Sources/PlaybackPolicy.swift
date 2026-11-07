import Foundation

struct PlaybackPolicy {
    static func isNetflix(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", (url.port == nil || url.port == 443),
              let host = url.host?.lowercased() else { return false }
        return host == "netflix.com" || host.hasSuffix(".netflix.com")
    }

    static func isWatching(_ url: URL?) -> Bool {
        isNetflix(url) && (url?.path.hasPrefix("/watch/") == true)
    }

    static func keepInApp(_ url: URL) -> Bool {
        guard url.scheme == "https", (url.port == nil || url.port == 443),
              let host = url.host?.lowercased() else { return false }
        return ["netflix.com", "netflix.net", "nflxvideo.net", "nflximg.net", "nflxext.com",
                "nflxso.net", "fast.com", "google.com", "gstatic.com", "recaptcha.net",
                "arkoselabs.com", "arkose.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

