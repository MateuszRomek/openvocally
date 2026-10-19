import Foundation
import GRDB
import Hotkeys
import Testing

@testable import Storage

private func insert(_ rows: [(String, Int, Int)], into database: AppDatabase) throws {
  try database.writer.write { db in
    for (action, key, modifiers) in rows {
      try db.execute(
        sql: "INSERT INTO shortcut_bindings (action, key_code, modifiers, updated_at) VALUES (?, ?, ?, 0)",
        arguments: [action, key, modifiers])
    }
  }
}

private let commandOptionK = KeyChord(KeyCode(rawValue: 40), [.command, .option])
private let commandOption = Int(Modifiers([.command, .option]).rawValue)

struct HotkeyDatabaseStoreTests {
  @Test func savedBindingsLoadBack() throws {
    let database = try AppDatabase.inMemory()
    let bindings = try HotkeyBindings.defaults.replacing(.toggle, with: .chord(commandOptionK))
    try database.saveHotkeyBindings(bindings)
    #expect(database.loadHotkeyBindings() == bindings)
  }

  @Test func doubleTapRowRoundTripsAsTheLeftKeycode() throws {
    let database = try AppDatabase.inMemory()
    let bindings = try HotkeyBindings.defaults.replacing(.pasteLast, with: .doubleTap(.command))
    try database.saveHotkeyBindings(bindings)
    let row = try database.writer.read {
      try Row.fetchOne(
        $0, sql: "SELECT key_code, modifiers FROM shortcut_bindings WHERE action = 'pasteLast'")
    }
    #expect(row?["key_code"] == 55)
    #expect(row?["modifiers"] == 0)
    #expect(database.loadHotkeyBindings() == bindings)
  }

  @Test func rightSideKeycodeRowLoadsAsADoubleTap() throws {
    let database = try AppDatabase.inMemory()
    try insert([("toggle", 61, 0)], into: database)
    let loaded = database.loadHotkeyBindings()
    #expect(loaded.trigger(for: .toggle) == .doubleTap(.option))
  }

  @Test func nothingStoredLoadsDefaults() throws {
    let database = try AppDatabase.inMemory()
    #expect(database.loadHotkeyBindings() == .defaults)
  }

  @Test func storedUnsafeChordLoadsDefaults() throws {
    let database = try AppDatabase.inMemory()
    try insert([("toggle", 9, Int(Modifiers.command.rawValue))], into: database)
    #expect(database.loadHotkeyBindings() == .defaults)
  }

  @Test func undefinedModifierBitsLoadDefaults() throws {
    let database = try AppDatabase.inMemory()
    try insert([("toggle", 40, commandOption | 0b1_0000)], into: database)
    #expect(database.loadHotkeyBindings() == .defaults)
  }

  @Test func storedChordEqualToAMissingActionsDefaultKeepsTheStoredOne() throws {
    let database = try AppDatabase.inMemory()
    try insert([("toggle", 49, Int(Modifiers.option.rawValue))], into: database)
    let loaded = database.loadHotkeyBindings()
    #expect(loaded.trigger(for: .toggle) == .chord(KeyChord(.space, [.option])))
    #expect(loaded.trigger(for: .pushToTalk) == nil)
    #expect(loaded.trigger(for: .cancel) == .chord(KeyChord(.escape)))
  }

  @Test func missingActionTakesItsDefault() throws {
    let database = try AppDatabase.inMemory()
    try insert([("toggle", 40, commandOption)], into: database)
    let loaded = database.loadHotkeyBindings()
    #expect(loaded.trigger(for: .toggle) == .chord(commandOptionK))
    #expect(loaded.trigger(for: .cancel) == .chord(KeyChord(.escape)))
    #expect(loaded.trigger(for: .pushToTalk) == .chord(KeyChord(.space, [.option])))
    #expect(loaded.trigger(for: .pasteLast) == .chord(KeyChord(.v, [.control, .option])))
  }

  @Test func duplicateChordCannotBeStored() throws {
    let database = try AppDatabase.inMemory()
    #expect(throws: DatabaseError.self) {
      try insert([("toggle", 40, commandOption), ("pasteLast", 40, commandOption)], into: database)
    }
  }
}
