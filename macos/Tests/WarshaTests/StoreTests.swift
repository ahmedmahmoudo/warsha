import Foundation
import Testing
@testable import Warsha

@MainActor
struct StoreTests {
  private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("warsha-tests-\(UUID().uuidString)")

  private func freshStore() throws -> Store {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = Store.open(at: folder.appendingPathComponent("warsha.sqlite"))
    #expect(store.error == nil)
    return store
  }

  @Test func todosKeepTheWebVersionsOrderAndDoneTime() throws {
    let store = try freshStore()
    store.addTodo("  later  ")
    store.addTodo("sooner", dueDate: "2026-10-20")
    store.addTodo("   ")
    #expect(store.todos.map(\.text) == ["sooner", "later"])

    let sooner = store.todos[0].id
    store.setTodo(sooner, done: true)
    let doneAt = try #require(store.todos.last?.doneAt)
    #expect(store.todos.map(\.text) == ["later", "sooner"])
    store.setTodo(sooner, done: true)
    #expect(store.todos.last?.doneAt == doneAt)

    store.updateTodo(sooner, dueDate: .some(nil))
    #expect(store.todos.last?.dueDate == nil)
    store.removeTodo(sooner)
    #expect(store.todos.map(\.text) == ["later"])
  }

  @Test func pinsNotesAndParkingUpsert() throws {
    let store = try freshStore()
    store.pin(ticketRef("MX-1"), title: "Old", url: nil)
    store.pin(ticketRef("MX-1"), title: "New", url: "https://linear.app")
    #expect(store.pins.map(\.title) == ["New"])

    store.setNote(prRef("everlab-au/ev-admin", 1), body: " hi ")
    #expect(store.notes.first?.body == "hi")
    store.setNote(prRef("everlab-au/ev-admin", 1), body: "")
    #expect(store.notes.isEmpty)

    store.park(ticketRef("MX-2"), title: "T", url: nil, reason: "waiting", until: "2026-11-01")
    store.park(ticketRef("MX-2"), title: "T", url: nil, reason: "still waiting", until: nil)
    #expect(store.parked.map(\.reason) == ["still waiting"])
    store.unpark(ticketRef("MX-2"))
    #expect(store.parked.isEmpty)
  }

  @Test func timestampsMatchJavaScriptsToISOString() {
    #expect(Store.timestamp(Date(timeIntervalSince1970: 1_760_000_000.123)) == "2025-10-09T08:53:20.123Z")
  }

  /// Copies the web version's real database (main file and WAL) and imports it.
  @Test func importsTheWebVersionsDatabase() throws {
    let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../../data/warsha.sqlite").standardized
    try #require(FileManager.default.fileExists(atPath: web.path), "No web database to import")

    let store = try freshStore()
    let copy = folder.appendingPathComponent("web.sqlite")
    for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: web.path + suffix) {
      try FileManager.default.copyItem(atPath: web.path + suffix, toPath: copy.path + suffix)
    }
    store.importDatabase(from: copy)
    #expect(store.error == nil)

    let check = try Database(path: copy.path)
    let count = { (table: String) in try check.query("select count(*) as n from \(table)").first?.integer("n") ?? -1 }
    #expect(Int64(store.pins.count) == (try count("pins")))
    #expect(Int64(store.parked.count) == (try count("parked")))
    #expect(Int64(store.notes.count) == (try count("notes")))
  }
}
