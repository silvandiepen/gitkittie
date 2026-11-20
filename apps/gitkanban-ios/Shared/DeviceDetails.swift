import UIKit

/// What a bug report needs to know about the device a screenshot was taken on.
enum DeviceDetails {
    /// The hardware identifier, e.g. "iPhone19,2".
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// True when the image has exactly this screen's pixel size, in either orientation:
    /// it is a screenshot taken on this device.
    static func isScreenshotOfThisDevice(_ pixelSize: CGSize?) -> Bool {
        guard let pixelSize else { return false }
        let native = UIScreen.main.nativeBounds.size
        return pixelSize == native || pixelSize == CGSize(width: native.height, height: native.width)
    }

    /// A Markdown section for the task. Nothing personal: no device name, no identifiers.
    static func markdown(appearance: UIUserInterfaceStyle, textSize: UIContentSizeCategory) -> String {
        let device = UIDevice.current
        let screen = UIScreen.main
        let native = screen.nativeBounds.size
        let look: String
        switch appearance {
        case .dark: look = "Dark"
        case .light: look = "Light"
        default: look = "Unspecified"
        }
        let size = textSize.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        return """
        ## Device
        - \(device.model) (\(modelIdentifier)), \(device.systemName) \(device.systemVersion)
        - Screen \(Int(native.width)) × \(Int(native.height)) px @\(Int(screen.nativeScale))x
        - \(look) appearance, text size \(size)
        - Locale \(Locale.current.identifier)
        """
    }
}
