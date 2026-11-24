import Foundation
import MailExtraction

// GitMailExtractor.xpc: turns attachment bytes into text for search, isolated from the app
// (ThreatModel §4). Sandboxed with no entitlements: it cannot reach the network or read any
// file; it only gets the bytes the app sends. A request running longer than the watchdog ends
// this process, and the app records no text for that attachment.

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let service = ExtractionService(watchdog: 20)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AttachmentTextExtractionXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
