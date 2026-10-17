import Foundation

/// A `ref` names what an item is about: "ticket:MX-2481" or "pr:everlab-au/ev-admin#18820".
typealias Ref = String

func ticketRef(_ key: String) -> Ref { "ticket:\(key)" }
func prRef(_ repo: String, _ number: Int) -> Ref { "pr:\(repo)#\(number)" }

/// Something you've chosen to focus on; it stays until you unpin it or it's done.
struct Pin: Equatable {
  let ref: Ref
  let title: String
  let url: String?
  let pinnedAt: String
}

struct Note: Equatable {
  let ref: Ref
  let body: String
  let updatedAt: String
}

struct Todo: Equatable, Identifiable {
  let id: Int64
  let text: String
  let ref: Ref?
  /// YYYY-MM-DD.
  let dueDate: String?
  let doneAt: String?
  let createdAt: String
}

/// Set aside on purpose: kept out of everything asking for your attention until you unpark it, or
/// until `until` (YYYY-MM-DD) passes. Parking a ticket parks its PRs too.
struct Parked: Equatable {
  let ref: Ref
  let title: String
  let url: String?
  let reason: String?
  let until: String?
  let parkedAt: String
}

/// Workbench's own data: what you pin, note, plan and park, plus settings and meetings as last
/// seen. One SQLite file with the same schema as the web version's, so its data imports as is.
/// Everything else is read live from GitHub, Linear and Google.
@MainActor
@Observable
final class Store {
  private(set) var pins: [Pin] = []
  private(set) var notes: [Note] = []
  private(set) var todos: [Todo] = []
  private(set) var parked: [Parked] = []
  /// The last failure, shown where the data is; nil once something works again.
  private(set) var error: String?

  let path: URL
  @ObservationIgnored private let db: Database?

  /// Each entry runs once, in order; the database remembers how far it got (user_version).
  /// Mirrors server/store/db.ts, so a file from either version opens in the other.
  private static let migrations = [
    """
    create table pins (ref text primary key, title text not null, url text, pinned_at text not null);
    create table notes (ref text primary key, body text not null, updated_at text not null);
    create table todos (
      id integer primary key autoincrement, text text not null, ref text, due_date text, done_at text,
      created_at text not null
    );
    create table settings (key text primary key, value text not null);
    """,
    """
    create table parked (
      ref text primary key, title text not null, url text, reason text, until text, parked_at text not null
    );
    """,
    """
    create table meetings (
      id text primary key, title text not null, start text not null, end text not null,
      all_day integer not null, join_url text, html_url text, location text,
      declined integer not null default 0, previous_start text, previous_end text,
      rescheduled_at text, deleted_at text, first_seen_at text not null, updated_at text not null
    );
    """,
  ]

  static let defaultPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Workbench/workbench.sqlite")

  static func open(at path: URL = defaultPath) -> Store {
    do {
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      let db = try Database(path: path.path)
      try db.execute("pragma journal_mode = wal; pragma foreign_keys = on;")
      try migrate(db)
      let store = Store(path: path, db: db)
      store.reload()
      return store
    } catch {
      let store = Store(path: path, db: nil)
      store.error = "Couldn't open \(path.path): \(error.localizedDescription)"
      return store
    }
  }

  private init(path: URL, db: Database?) {
    self.path = path
    self.db = db
  }

  private static func migrate(_ db: Database) throws {
    let version = Int(try db.query("pragma user_version").first?.integer("user_version") ?? 0)
    for index in version ..< migrations.count {
      try db.execute("begin")
      do {
        try db.execute(migrations[index])
        try db.execute("pragma user_version = \(index + 1)")
        try db.execute("commit")
      } catch {
        try? db.execute("rollback")
        throw error
      }
    }
  }

  /// Replaces everything with the web version's data/workbench.sqlite.
  func importDatabase(from source: URL) {
    write {
      try $0.restore(from: source.path)
      try Self.migrate($0)
    }
  }

  // MARK: Reads

  private func reload() {
    guard let db else { return }
    do {
      pins = try db.query("select * from pins order by pinned_at").map {
        Pin(ref: $0.string("ref")!, title: $0.string("title")!, url: $0.string("url"), pinnedAt: $0.string("pinned_at")!)
      }
      notes = try db.query("select * from notes order by updated_at desc").map {
        Note(ref: $0.string("ref")!, body: $0.string("body")!, updatedAt: $0.string("updated_at")!)
      }
      // Open ones first (dated soonest first), then the last week's done ones.
      todos = try db.query(
        """
        select * from todos where done_at is null or done_at >= ?
        order by done_at is not null, coalesce(due_date, '9999'), created_at
        """,
        .text(Self.timestamp(Date(timeIntervalSinceNow: -7 * 86_400)))
      ).map {
        Todo(
          id: $0.integer("id")!, text: $0.string("text")!, ref: $0.string("ref"), dueDate: $0.string("due_date"),
          doneAt: $0.string("done_at"), createdAt: $0.string("created_at")!
        )
      }
      parked = try db.query("select * from parked order by parked_at desc").map {
        Parked(
          ref: $0.string("ref")!, title: $0.string("title")!, url: $0.string("url"), reason: $0.string("reason"),
          until: $0.string("until"), parkedAt: $0.string("parked_at")!
        )
      }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: Writes

  func pin(_ ref: Ref, title: String, url: String?) {
    write {
      try $0.run(
        """
        insert into pins (ref, title, url, pinned_at) values (?, ?, ?, ?)
        on conflict(ref) do update set title = excluded.title, url = excluded.url
        """,
        .text(ref), .text(title), .nullable(url), .text(Self.now())
      )
    }
  }

  func unpin(_ ref: Ref) {
    write { try $0.run("delete from pins where ref = ?", .text(ref)) }
  }

  /// An empty body deletes the note.
  func setNote(_ ref: Ref, body: String) {
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    write {
      if body.isEmpty {
        try $0.run("delete from notes where ref = ?", .text(ref))
      } else {
        try $0.run(
          """
          insert into notes (ref, body, updated_at) values (?, ?, ?)
          on conflict(ref) do update set body = excluded.body, updated_at = excluded.updated_at
          """,
          .text(ref), .text(body), .text(Self.now())
        )
      }
    }
  }

  func addTodo(_ text: String, ref: Ref? = nil, dueDate: String? = nil) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    write {
      try $0.run(
        "insert into todos (text, ref, due_date, created_at) values (?, ?, ?, ?)",
        .text(text), .nullable(ref), .nullable(dueDate), .text(Self.now())
      )
    }
  }

  /// Marking done keeps the first time it was done.
  func setTodo(_ id: Int64, done: Bool) {
    write {
      try $0.run(
        "update todos set done_at = case when ? then coalesce(done_at, ?) else null end where id = ?",
        .integer(done ? 1 : 0), .text(Self.now()), .integer(id)
      )
    }
  }

  func updateTodo(_ id: Int64, text: String? = nil, dueDate: String?? = nil) {
    write {
      if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        try $0.run("update todos set text = ? where id = ?", .text(text), .integer(id))
      }
      if let dueDate {
        try $0.run("update todos set due_date = ? where id = ?", .nullable(dueDate), .integer(id))
      }
    }
  }

  func removeTodo(_ id: Int64) {
    write { try $0.run("delete from todos where id = ?", .integer(id)) }
  }

  /// Parking again updates the reason and date.
  func park(_ ref: Ref, title: String, url: String?, reason: String?, until: String?) {
    write {
      try $0.run(
        """
        insert into parked (ref, title, url, reason, until, parked_at) values (?, ?, ?, ?, ?, ?)
        on conflict(ref) do update set title = excluded.title, url = excluded.url, reason = excluded.reason,
          until = excluded.until
        """,
        .text(ref), .text(title), .nullable(url), .nullable(reason), .nullable(until), .text(Self.now())
      )
    }
  }

  func unpark(_ ref: Ref) {
    write { try $0.run("delete from parked where ref = ?", .text(ref)) }
  }

  /// Small values Workbench keeps for itself (not credentials; those live in the Keychain).
  func setting(_ key: String) -> String? {
    try? db?.query("select value from settings where key = ?", .text(key)).first?.string("value")
  }

  func setSetting(_ key: String, _ value: String?) {
    write {
      if let value {
        try $0.run(
          "insert into settings (key, value) values (?, ?) on conflict(key) do update set value = excluded.value",
          .text(key), .text(value)
        )
      } else {
        try $0.run("delete from settings where key = ?", .text(key))
      }
    }
  }

  private func write(_ change: (Database) throws -> Void) {
    guard let db else { return }
    do {
      try change(db)
      reload()
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Timestamps as the web version writes them (JavaScript's toISOString), so both sort together.
  /// Milliseconds are written from a whole number: the formatter's own fractions truncate the
  /// double, turning .123 into .122.
  nonisolated static func timestamp(_ date: Date) -> String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
    let seconds = Date(timeIntervalSince1970: TimeInterval(milliseconds / 1000)).formatted(.iso8601)
    return seconds.dropLast() + String(format: ".%03dZ", milliseconds % 1000)
  }

  private static func now() -> String { timestamp(Date()) }
}
