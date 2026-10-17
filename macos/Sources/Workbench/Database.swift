import Foundation
import SQLite3

/// A small SQLite wrapper over the system library: run statements with bound values and read rows
/// back by column name.
final class Database {
  enum Value: Equatable {
    case text(String)
    case integer(Int64)
    case null
  }

  struct Row {
    fileprivate let values: [String: Value]

    func string(_ column: String) -> String? {
      if case let .text(value) = values[column] { return value }
      return nil
    }

    func integer(_ column: String) -> Int64? {
      if case let .integer(value) = values[column] { return value }
      return nil
    }
  }

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private var handle: OpaquePointer?

  init(path: String) throws {
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
      sqlite3_close(handle)
      throw Failure(message: message)
    }
  }

  deinit { sqlite3_close(handle) }

  /// Runs one or more statements with no values or results, like migrations.
  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? lastError
      sqlite3_free(error)
      throw Failure(message: message)
    }
  }

  func query(_ sql: String, _ values: Value...) throws -> [Row] {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    var rows: [Row] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: rows.append(row(statement))
      case SQLITE_DONE: return rows
      default: throw Failure(message: lastError)
      }
    }
  }

  /// Runs a write; returns how many rows changed and the last inserted id.
  @discardableResult
  func run(_ sql: String, _ values: Value...) throws -> (changes: Int, lastInsertId: Int64) {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: lastError) }
    return (Int(sqlite3_changes(handle)), sqlite3_last_insert_rowid(handle))
  }

  /// Replaces this database's contents with another file's, WAL included, through SQLite's backup API.
  func restore(from path: String) throws {
    var source: OpaquePointer?
    defer { sqlite3_close(source) }
    guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let backup = sqlite3_backup_init(handle, "main", source, "main")
    else { throw Failure(message: source.map { String(cString: sqlite3_errmsg($0)) } ?? lastError) }
    let result = sqlite3_backup_step(backup, -1)
    sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE else { throw Failure(message: lastError) }
  }

  private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

  private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure(message: lastError) }
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case let .text(text): sqlite3_bind_text(statement, position, text, -1, transient)
      case let .integer(number): sqlite3_bind_int64(statement, position, number)
      case .null: sqlite3_bind_null(statement, position)
      }
    }
    return statement
  }

  private func row(_ statement: OpaquePointer?) -> Row {
    var values: [String: Value] = [:]
    for column in 0 ..< sqlite3_column_count(statement) {
      let name = String(cString: sqlite3_column_name(statement, column))
      values[name] = switch sqlite3_column_type(statement, column) {
      case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
      case SQLITE_NULL: .null
      default: .text(String(cString: sqlite3_column_text(statement, column)))
      }
    }
    return Row(values: values)
  }
}

/// Tells SQLite to copy bound text, since Swift's string buffer doesn't outlive the call.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Database.Value {
  static func nullable(_ value: String?) -> Self { value.map { .text($0) } ?? .null }
}
