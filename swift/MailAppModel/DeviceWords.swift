import Foundation

/// How the app names the device it runs on, in messages shared by the Mac and the iPhone and
/// iPad apps: "this Mac" on the Mac, "this iPhone" or "this iPad" on iOS.
enum DeviceWords {
    static var this: String { "this " + model }

    /// "This Mac", for the start of a sentence.
    static var thisAtStart: String { "This " + model }

    /// "Mac", "iPhone" or "iPad".
    static var model: String {
        #if os(macOS)
        "Mac"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : (isPad ? "iPad" : "iPhone")
        #endif
    }

    #if !os(macOS)
    /// Read from the hardware model name, so this file stays free of UIKit.
    private static var isPad: Bool {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if machine.hasPrefix("iPad") { return true }
        if machine.hasPrefix("iPhone") { return false }
        // The simulator reports the Mac's architecture; it names the simulated device here.
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
    }
    #endif
}
