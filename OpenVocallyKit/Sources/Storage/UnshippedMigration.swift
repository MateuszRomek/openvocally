#if DEBUG
  import GRDB

  extension DatabaseMigrator {
    /// The migration of a feature still behind its Debug-only flag. Its identifier carries a hash
    /// of `sql`, so an edited schema runs again on every Debug database, after dropping the
    /// feature's tables, which hold only Debug data. It exists only in Debug, so a call left
    /// outside its flag fails the Release build. When the feature ships, register `sql` as the
    /// next `vN` and record its snapshot, which `SnapshotMigrationTests` asks for.
    mutating func registerUnshippedMigration(_ feature: String, tablePrefix: String, sql: String) {
      registerMigration("\(Self.unshippedPrefix)\(feature)-\(Self.fnv1a(sql))") { db in
        let pattern = tablePrefix.replacingOccurrences(of: "_", with: "\\_") + "%"
        let tables = try String.fetchAll(
          db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE ? ESCAPE '\\'",
          arguments: [pattern])
        for table in tables { try db.drop(table: table) }
        try db.execute(sql: sql)
      }
    }

    static let unshippedPrefix = "unshipped-"

    /// Stable across launches, unlike `Hasher`, which is seeded per process.
    private static func fnv1a(_ text: String) -> String {
      var hash: UInt64 = 0xcbf2_9ce4_8422_2325
      for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
      }
      return String(hash, radix: 16)
    }
  }
#endif
