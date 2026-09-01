import Foundation
import SQLite3

/// Read-only access to a VS Code-derivative's `state.vscdb` SQLite database,
/// used to read Cursor's `ItemTable(key, value)` credential rows without
/// copying or writing to the live file.
struct CursorStateStore {
    let databaseURL: URL

    func readItem(_ key: String) -> String? {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        guard open(&db, mode: "mode=ro") || open(&db, mode: "immutable=1") else { return nil }

        var statement: OpaquePointer?
        defer { if statement != nil { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func open(_ db: inout OpaquePointer?, mode: String) -> Bool {
        if db != nil { sqlite3_close(db); db = nil }
        var allowedInPath = CharacterSet.urlPathAllowed
        allowedInPath.remove(charactersIn: "?#")
        guard let encodedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: allowedInPath) else { return false }
        let uri = "file:\(encodedPath)?\(mode)"
        return sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
    }
}
