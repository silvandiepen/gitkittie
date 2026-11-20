import XCTest
@testable import GitKanbanKit

@MainActor
final class FolderServerBrowserTests: XCTestCase {
    func testReadsTheAddressFromTheTXTRecord() {
        let server = DiscoveredServer(name: "Projects on Mac", txt: ["root": "Projects", "url": "https://mac.tail.ts.net"])
        XCTAssertEqual(server.url, "https://mac.tail.ts.net")
        XCTAssertEqual(server.root, "Projects")
        XCTAssertNil(DiscoveredServer(name: "x", txt: [:]).url)
        XCTAssertNil(DiscoveredServer(name: "x", txt: ["url": "not a url"]).url)
        XCTAssertNil(DiscoveredServer(name: "x", txt: ["url": "ftp://mac"]).url)
    }

    #if os(macOS)
    /// Announces a real service with the system's `dns-sd` and finds it with the browser.
    func testFindsAnAnnouncedServer() async throws {
        let name = "GitKanban test \(UUID().uuidString.prefix(8))"
        let announce = Process()
        announce.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        announce.arguments = ["-R", name, DiscoveredServer.serviceType, "local", "4499", "v=1", "root=Projects", "url=http://127.0.0.1:4499"]
        announce.standardOutput = FileHandle.nullDevice
        try announce.run()
        defer { announce.terminate() }

        let browser = FolderServerBrowser()
        browser.start()
        defer { browser.stop() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !browser.servers.contains(where: { $0.name == name }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let found = try XCTUnwrap(browser.servers.first { $0.name == name }, browser.problem ?? "not found")
        XCTAssertEqual(found.url, "http://127.0.0.1:4499")
        XCTAssertEqual(found.root, "Projects")
    }
    #endif
}
