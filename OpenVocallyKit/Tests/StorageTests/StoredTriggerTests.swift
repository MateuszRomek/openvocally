import Foundation
import GRDB
import Hotkeys
import Testing

@testable import Storage

struct StoredTriggerTests {
  @Test(arguments: HoldKey.allCases)
  func `a hold round trips with the 0x80 marker`(key: HoldKey) {
    let columns = StoredTrigger.columns(.hold(key))
    #expect(columns.modifiers == 0x80)
    #expect(columns.keyCode == Int(key.keyCode.rawValue))
    #expect(
      StoredTrigger.trigger(keyCode: Int64(columns.keyCode), modifiers: Int64(columns.modifiers))
        == .hold(key))
  }

  @Test func `a double tap is still the left keycode with no modifiers`() {
    #expect(StoredTrigger.trigger(keyCode: 55, modifiers: 0) == .doubleTap(.command))
    #expect(StoredTrigger.columns(.doubleTap(.command)) == (keyCode: 55, modifiers: 0))
  }

  @Test func `a chord row is unchanged`() {
    #expect(StoredTrigger.trigger(keyCode: 49, modifiers: 4) == .chord(KeyChord(.space, [.option])))
    #expect(StoredTrigger.columns(.chord(KeyChord(.space, [.option]))) == (keyCode: 49, modifiers: 4))
  }

  @Test func `hold and double tap rows never collide`() {
    let holds = HoldKey.allCases.map { StoredTrigger.columns(.hold($0)) }
    let doubleTaps = ModifierKey.allCases.map { StoredTrigger.columns(.doubleTap($0)) }
    for hold in holds {
      #expect(!doubleTaps.contains { $0 == hold })
    }
  }

  @Test func `the marker with a non-hold keycode is unusable`() {
    #expect(StoredTrigger.trigger(keyCode: 49, modifiers: 0x80) == nil)
  }

  /// Canary: the hold marker must never become a legal chord, or a hold row would load as one
  /// and an older build would not fall back to the defaults.
  @Test func `the hold marker is never a valid modifier set`() {
    #expect(Modifiers(validating: StoredTrigger.holdMarker) == nil)
  }

  @Test func `a hold binding survives the database`() throws {
    let database = try AppDatabase.inMemory()
    let bindings = try HotkeyBindings.defaults.replacing(.pushToTalk, with: .hold(.rightCommand))
    try database.saveHotkeyBindings(bindings)
    #expect(database.loadHotkeyBindings() == bindings)
    let row = try database.writer.read {
      try Row.fetchOne(
        $0, sql: "SELECT key_code, modifiers FROM shortcut_bindings WHERE action = 'pushToTalk'")
    }
    #expect(row?["key_code"] == 54)
    #expect(row?["modifiers"] == 0x80)
  }

  @Test func `an unusable marker row loads the defaults`() throws {
    let database = try AppDatabase.inMemory()
    try database.writer.write { db in
      try db.execute(
        sql:
          "INSERT INTO shortcut_bindings (action, key_code, modifiers, updated_at) VALUES ('pushToTalk', 49, 128, 0)"
      )
    }
    #expect(database.loadHotkeyBindings() == .defaults)
  }
}
