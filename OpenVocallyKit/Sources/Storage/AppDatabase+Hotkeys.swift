import Foundation
import GRDB
import Hotkeys
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "storage")

extension AppDatabase {
  /// Bindings in `shortcut_bindings`. Nothing stored, or a read failure, loads the defaults.
  public func loadHotkeyBindings() -> HotkeyBindings {
    do {
      let rows = try writer.read {
        try Row.fetchAll($0, sql: "SELECT action, key_code, modifiers FROM shortcut_bindings")
      }
      return Self.bindings(from: rows)
    } catch {
      logger.error(
        "Loading hotkey bindings failed, using defaults: \(String(describing: error), privacy: .private)")
      return .defaults
    }
  }

  public func saveHotkeyBindings(_ bindings: HotkeyBindings) throws {
    let now = unixMilliseconds(.now)
    try writer.write { db in
      try db.execute(sql: "DELETE FROM shortcut_bindings")
      for (action, trigger) in bindings.triggers {
        let (keyCode, modifiers) = StoredTrigger.columns(trigger)
        try db.execute(
          sql: "INSERT INTO shortcut_bindings (action, key_code, modifiers, updated_at) VALUES (?, ?, ?, ?)",
          arguments: [action.rawValue, keyCode, modifiers, now])
      }
    }
  }

  private static func bindings(from rows: [Row]) -> HotkeyBindings {
    var stored: [String: HotkeyTrigger] = [:]
    for row in rows {
      guard let trigger = StoredTrigger.trigger(keyCode: row["key_code"], modifiers: row["modifiers"]) else {
        logger.error("Stored hotkey binding has an unusable chord, using defaults")
        return .defaults
      }
      stored[row["action"]] = trigger
    }
    return HotkeyBindings.loading(stored: stored)
  }
}
