import Foundation

enum AppBuildInfo {
    static let releaseVersion = value(for: "CFBundleShortVersionString", fallback: "development")
    static let buildVersion = value(
        for: "SwiftRDPBuildVersion",
        fallback: value(for: "CFBundleVersion", fallback: "development")
    )

    private static func value(for key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return fallback
        }
        return value
    }
}
