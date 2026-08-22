import Foundation
import SQLite3

/// Read tables out of a SQLite database file using the system SQLite3 C API.
public enum SQLiteReader {

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func tableNames(url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw AlembicError.unreadableFile(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AlembicError.parseFailure("Cannot enumerate SQLite tables")
        }
        defer { sqlite3_finalize(stmt) }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: c))
            }
        }
        return names
    }

    public static func read(url: URL, table: String, limit: Int? = nil) throws -> Dataset {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw AlembicError.unreadableFile(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }

        // Table name goes through identifier quoting (cannot be bound as a parameter)
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var sql = "SELECT * FROM \(quoted)"
        if let limit { sql += " LIMIT \(max(0, limit))" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AlembicError.parseFailure("Cannot read table \(table)")
        }
        defer { sqlite3_finalize(stmt) }

        let colCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = []
        for i in 0..<colCount {
            columns.append(sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "column_\(i + 1)")
        }

        var rows: [[Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Value] = []
            row.reserveCapacity(colCount)
            for i in 0..<colCount {
                let ci = Int32(i)
                switch sqlite3_column_type(stmt, ci) {
                case SQLITE_NULL:
                    row.append(.null)
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(stmt, ci)))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(stmt, ci)))
                case SQLITE_TEXT:
                    row.append(sqlite3_column_text(stmt, ci).map { .string(String(cString: $0)) } ?? .null)
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, ci)
                    row.append(.string("<blob \(bytes) bytes>"))
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return Dataset.fresh(columns: columns, rows: rows)
    }
}
