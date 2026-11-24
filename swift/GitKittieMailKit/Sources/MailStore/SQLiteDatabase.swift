import Foundation
import SQLite3

/// A thin, throwing wrapper over the system SQLite (which ships with FTS5 on macOS and iOS), so
/// the store needs no third-party dependency. One connection, used from one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw MailStoreError.sqlite(code: code, message: message)
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw MailStoreError.sqlite(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw lastError(code) }
        return Statement(statement, database: self)
    }

    /// Run `body` in one transaction: all of it lands, or none of it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws {
            let statement = try prepare("PRAGMA user_version")
            guard try statement.step() else { return 0 }
            return statement.int(0)
        }
    }

    /// The rowid of the last row inserted on this connection.
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    /// Rows the last statement inserted, updated or deleted.
    var changes: Int { Int(sqlite3_changes(handle)) }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    fileprivate func lastError(_ code: Int32) -> MailStoreError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    final class Statement {
        private let statement: OpaquePointer
        private unowned let database: SQLiteDatabase
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
            self.statement = statement
            self.database = database
        }

        deinit { sqlite3_finalize(statement) }

        @discardableResult
        func bind(_ values: [SQLiteValue]) throws -> Statement {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch value {
                case .null: code = sqlite3_bind_null(statement, index)
                case .int(let v): code = sqlite3_bind_int64(statement, index, v)
                case .double(let v): code = sqlite3_bind_double(statement, index, v)
                case .text(let v): code = sqlite3_bind_text(statement, index, v, -1, Self.transient)
                }
                guard code == SQLITE_OK else { throw database.lastError(code) }
            }
            return self
        }

        /// Step once: true while there is a row.
        func step() throws -> Bool {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw database.lastError(code)
            }
        }

        func run(_ values: [SQLiteValue] = []) throws {
            try bind(values)
            while try step() {}
        }

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    static func optional(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}
