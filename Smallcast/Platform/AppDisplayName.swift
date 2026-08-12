import Foundation

extension Bundle {
    /// The channel-aware display name, from the generated Info.plist.
    var appDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Smallcast"
    }
}
