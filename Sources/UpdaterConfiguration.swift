import Foundation

enum UpdaterConfiguration {
    static func isValid(feedURL: String?, publicKey: String?) -> Bool {
        guard let feedURL, let components = URLComponents(string: feedURL),
              components.scheme == "https", components.host != nil,
              let publicKey, let decoded = Data(base64Encoded: publicKey), decoded.count == 32 else { return false }
        return true
    }
}
