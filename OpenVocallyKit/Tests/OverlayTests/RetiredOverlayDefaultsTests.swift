import Foundation
import Testing

@testable import Overlay

struct RetiredOverlayDefaultsTests {
  @Test func `both retired keys go and other settings stay, run after run`() throws {
    let suite = "RetiredOverlayDefaultsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("island", forKey: "overlayStyle")
    defaults.set("islandTop", forKey: "overlayPlacement")
    defaults.set("dark", forKey: "appTheme")

    for _ in 0..<2 {
      RetiredOverlayDefaults.remove(from: defaults)
      #expect(defaults.object(forKey: "overlayStyle") == nil)
      #expect(defaults.object(forKey: "overlayPlacement") == nil)
      #expect(defaults.string(forKey: "appTheme") == "dark")
    }
  }
}
