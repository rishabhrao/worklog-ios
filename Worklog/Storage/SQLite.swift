import Foundation
import SQLite3

/// Minimal hand-rolled wrapper over the system `libsqlite3` C API - no
/// external package dependency, consistent with the rest of the app (Apple
/// system frameworks only, no bundled runtime). `worklog.db` is small and
/// low-concurrency (one app, occasional writes), so a thin synchronous
/// wrapper is all this needs; there is no ORM/migration layer because there
/// is exactly one schema version and one place it's defined (`Database.open`).
final class SQLite {
    enum SQLiteError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case bindFailed(String)
    }

    private let db: OpaquePointer
    // WorklogDatabase.shared is a singleton hit from many independent
    // background Task.detached contexts (transcription pipeline, range
    // loading, startup reconciliation, the live-refresh timer, the manual
    // Refresh button...) with no coordination between them. sqlite3_open's
    // default threading mode does not make a single connection handle safe
    // for concurrent use from multiple threads at once - two calls into
    // sqlite3_prepare_v2 on the same handle at the same time crashed with
    // SIGSEGV inside sqlite3ParseObjectReset (confirmed via a real crash
    // report: ClipScreenViewModel.refresh()'s RangeLoader.load call
    // colliding with a concurrent query). Serialize every execute/query
    // call through this queue so the underlying handle is never touched
    // from two threads simultaneously, regardless of how many independent
    // background tasks call into WorklogDatabase.
    private let queue = DispatchQueue(label: "worklog.sqlite")

    init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open(path, &handle)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw SQLiteError.openFailed(message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Runs a statement with no result rows (DDL, INSERT/UPDATE/DELETE).
    @discardableResult
    func execute(_ sql: String, _ bindings: [Bindable] = []) throws -> Int {
        try queue.sync {
            let statement = try prepare(sql, bindings)
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else {
                throw SQLiteError.stepFailed(lastErrorMessage())
            }
            return Int(sqlite3_changes(db))
        }
    }

    /// Runs a SELECT, calling `row` once per result row.
    func query(_ sql: String, _ bindings: [Bindable] = [], row: (Row) -> Void) throws {
        try queue.sync {
            let statement = try prepare(sql, bindings)
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW {
                    row(Row(statement: statement))
                } else if status == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.stepFailed(lastErrorMessage())
                }
            }
        }
    }

    private func prepare(_ sql: String, _ bindings: [Bindable]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        for (index, binding) in bindings.enumerated() {
            let status = binding.bind(to: statement, index: Int32(index + 1))
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError.bindFailed(lastErrorMessage())
            }
        }
        return statement
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

/// A value that knows how to bind itself into a prepared statement slot.
protocol Bindable {
    func bind(to statement: OpaquePointer, index: Int32) -> Int32
}

extension String: Bindable {
    func bind(to statement: OpaquePointer, index: Int32) -> Int32 {
        sqlite3_bind_text(statement, index, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

extension Int: Bindable {
    func bind(to statement: OpaquePointer, index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, Int64(self))
    }
}

extension Double: Bindable {
    func bind(to statement: OpaquePointer, index: Int32) -> Int32 {
        sqlite3_bind_double(statement, index, self)
    }
}

/// Binds raw bytes as a SQL BLOB - used for the waveform peak-cache
/// (`segment_peaks.peaks`), the one column in the schema that isn't a
/// scalar text/int/real value.
struct BlobBinding: Bindable {
    let data: Data

    func bind(to statement: OpaquePointer, index: Int32) -> Int32 {
        data.withUnsafeBytes { pointer in
            sqlite3_bind_blob(statement, index, pointer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

/// Wraps `Optional` so `nil` binds as SQL NULL - only for the wrapped types
/// used by this app's schema (String/Int/Double), not a general-purpose
/// conformance.
struct NullableBinding<Wrapped>: Bindable where Wrapped: Bindable {
    let value: Wrapped?

    func bind(to statement: OpaquePointer, index: Int32) -> Int32 {
        guard let value else { return sqlite3_bind_null(statement, index) }
        return value.bind(to: statement, index: index)
    }
}

extension Optional where Wrapped: Bindable {
    var asBindable: Bindable {
        NullableBinding(value: self)
    }
}

/// Column accessors for a single result row, indexed by 0-based column position.
struct Row {
    let statement: OpaquePointer

    func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func int(_ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    func blob(_ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }
}
