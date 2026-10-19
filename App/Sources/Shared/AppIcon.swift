import AppKit
import DesignSystem
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The app's Finder icon, or the system's generic application icon for an app that is not
/// installed, not known yet or not resolved yet.
struct AppIcon: View {
  let bundleID: String?
  var size: IconSize = .row

  var body: some View {
    Image(nsImage: AppIconCache.shared.icon(for: bundleID))
      .resizable()
      .frame(width: size.points, height: size.points)
      .accessibilityHidden(true)
  }
}

/// Resolves each bundle id's icon once, off the main actor, including a miss. `warm` runs when
/// the database opens and when a page of transcripts arrives, so icons are usually ready before
/// a screen draws them; a view that asks first shows the generic icon and redraws when it lands.
@MainActor @Observable final class AppIconCache {
  static let shared = AppIconCache()

  /// The Finder's icon for an application bundle, for a missing or unknown app.
  nonisolated static let generic = NSWorkspace.shared.icon(for: .applicationBundle)

  private var icons: [String: NSImage] = [:]
  @ObservationIgnored private var requested: Set<String> = []

  func icon(for bundleID: String?) -> NSImage {
    guard let bundleID else { return Self.generic }
    if let icon = icons[bundleID] { return icon }
    warm([bundleID])
    return Self.generic
  }

  /// Resolves the ids not asked for before, in one batch, and publishes them together.
  func warm(_ bundleIDs: some Sequence<String>) {
    let missing = Set(bundleIDs).subtracting(requested)
    guard !missing.isEmpty else { return }
    requested.formUnion(missing)
    Task {
      let resolved = await Self.resolve(missing)
      icons.merge(resolved) { current, _ in current }
    }
  }

  @concurrent private nonisolated static func resolve(_ bundleIDs: Set<String>) async -> [String: NSImage] {
    var icons: [String: NSImage] = [:]
    for bundleID in bundleIDs {
      let workspace = NSWorkspace.shared
      icons[bundleID] =
        workspace.urlForApplication(withBundleIdentifier: bundleID).map { workspace.icon(forFile: $0.path) }
        ?? generic
    }
    return icons
  }
}
