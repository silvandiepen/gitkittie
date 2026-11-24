import Foundation
import MailProvider
import MailSpikeKit

// gkmail-spike — the GKM-004 end-to-end run. See README.md in this package.
//
//   gkmail-spike --local
//       against scripts/test-mail-server.sh (synthetic account, local test CA)
//   gkmail-spike --icloud you@icloud.com [--keychain-service gitkittie-mail-spike]
//       against iCloud; the app-specific password is read from the login Keychain
//   gkmail-spike --account you@example.com --imap host:993 --smtp host:465|587 [...]
//       any IMAP/SMTP account (implicit TLS for 993/465, STARTTLS for 587)
//
//   --log-file PATH   where the full protocol log goes (default: ./gkmail-spike.log)
//   --verbose         also print debug lines to the terminal

struct Options {
    var mode = ""
    var account = ""
    var keychainService = "gitkittie-mail-spike"
    var imap: String?
    var smtp: String?
    var logFile = "gkmail-spike.log"
    var verbose = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: gkmail-spike --local
           gkmail-spike --icloud ADDRESS [--keychain-service NAME]
           gkmail-spike --account ADDRESS --imap HOST:PORT --smtp HOST:PORT [--keychain-service NAME]
           [--log-file PATH] [--verbose]

    """.utf8))
    exit(2)
}

func value(_ arguments: inout IndexingIterator<ArraySlice<String>>) -> String {
    guard let next = arguments.next() else { usage() }
    return next
}

func parse() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--local": options.mode = "local"
        case "--icloud": options.mode = "icloud"; options.account = value(&arguments)
        case "--account": options.mode = "custom"; options.account = value(&arguments)
        case "--imap": options.imap = value(&arguments)
        case "--smtp": options.smtp = value(&arguments)
        case "--keychain-service": options.keychainService = value(&arguments)
        case "--log-file": options.logFile = value(&arguments)
        case "--verbose": options.verbose = true
        default: usage()
        }
    }
    if options.mode.isEmpty { usage() }
    return options
}

func endpoint(_ text: String?, smtp: Bool) -> ServerEndpoint {
    guard let text, let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { usage() }
    let host = String(text[..<colon])
    let security: TransportSecurity = smtp && port == 587 ? .startTLS : .implicitTLS
    return ServerEndpoint(host: host, port: port, security: security)
}

let options = parse()
let configuration: SpikeConfiguration
do {
    switch options.mode {
    case "local":
        let state = ProcessInfo.processInfo.environment["GKM_TEST_MAIL_SERVER_DIR"]
            ?? NSHomeDirectory() + "/Library/Caches/GitKittieMail/test-mail-server"
        let ca = try Data(contentsOf: URL(fileURLWithPath: state + "/tls/ca.pem"))
        // The local server's synthetic account; its password is published in the script.
        let credential = MailCredential.password(username: "spike@example.com", password: Secret("gkm-local-test-password"))
        configuration = SpikeConfiguration(
            address: "spike@example.com",
            imap: ServerEndpoint(host: "localhost", port: 3993, security: .implicitTLS, trust: .customRoots(pem: [ca])),
            smtp: ServerEndpoint(host: "localhost", port: 3465, security: .implicitTLS, trust: .customRoots(pem: [ca])),
            credential: credential, arrivalTimeout: .seconds(20)
        )
    case "icloud":
        let password = try KeychainPassword.read(service: options.keychainService, account: options.account)
        configuration = SpikeConfiguration(
            address: options.account, imap: .iCloudIMAP, smtp: .iCloudSMTP,
            credential: .password(username: options.account, password: password)
        )
    default:
        let password = try KeychainPassword.read(service: options.keychainService, account: options.account)
        configuration = SpikeConfiguration(
            address: options.account, imap: endpoint(options.imap, smtp: false), smtp: endpoint(options.smtp, smtp: true),
            credential: .password(username: options.account, password: password)
        )
    }
} catch {
    FileHandle.standardError.write(Data("gkmail-spike: \(error)\n".utf8))
    exit(1)
}

FileManager.default.createFile(atPath: options.logFile, contents: nil, attributes: [.posixPermissions: 0o600])
guard let logHandle = FileHandle(forWritingAtPath: options.logFile) else {
    FileHandle.standardError.write(Data("gkmail-spike: cannot write \(options.logFile)\n".utf8))
    exit(1)
}
let verbose = options.verbose
let log = MailLog(minimumLevel: .trace) { record in
    let line = "\(ISO8601DateFormatter().string(from: record.date)) [\(record.level)] \(record.category): \(record.message)\n"
    logHandle.write(Data(line.utf8))
    if record.level >= .info || verbose { FileHandle.standardError.write(Data(line.utf8)) }
}

let report = await SpikeScenario(configuration: configuration, log: log).run()
try? logHandle.synchronize()
try? logHandle.close()

print("\nGKM-004 spike against \(configuration.imap.host) / \(configuration.smtp.host)")
for step in report.steps {
    print("\(step.passed ? "PASS" : "FAIL")  \(step.name)")
    for note in step.notes { print("      \(note)") }
}

// Acceptance: no password or token in any log.
let logText = (try? String(contentsOfFile: options.logFile, encoding: .utf8)) ?? ""
let leaked = configuration.credential.secret.withValue { secret in
    logText.contains(secret) || logText.contains(Data(secret.utf8).base64EncodedString())
}
print("\(leaked ? "FAIL" : "PASS")  No password in the log (\(options.logFile), \(logText.utf8.count) bytes)")
exit(report.passed && !leaked ? 0 : 1)
