import AppKit

enum SafariUserAgent {
    static let fallbackVersion = "17.6"
    private static let versionPattern = #"^[0-9]+(?:\.[0-9]+)+$"#

    static var current: String {
        let version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return make(installedVersion: version)
    }

    static func make(installedVersion: String?) -> String {
        let version = installedVersion.flatMap(validatedVersion) ?? fallbackVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }

    private static func validatedVersion(_ value: String) -> String? {
        value.range(of: versionPattern, options: .regularExpression) == nil ? nil : value
    }
}
