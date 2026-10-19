import DesignSystem

/// Declaration order is priority: dictation always wins the main shape, because its latency
/// budget matters most.
public enum OverlaySource: Int, CaseIterable, Sendable, Comparable {
  case dictation
  case agent

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Derived from the slots, never stored apart from them. One island at a time: a lower
/// source waits until the higher one clears.
struct OverlayScene: Equatable {
  let primary: OverlayActivity?

  static let hidden = OverlayScene(primary: nil)

  init(primary: OverlayActivity?) {
    self.primary = primary
  }

  init(_ slots: [OverlaySource: OverlayActivity]) {
    self.init(primary: OverlaySource.allCases.lazy.compactMap { slots[$0] }.first)
  }

  var level: OverlayLevel { primary?.level ?? .hidden }

  /// One curve drives the whole island, shape and content, so the text never outruns
  /// the edge. A change within a level is a content swap.
  static func motion(from old: OverlayScene, to new: OverlayScene) -> Motion {
    if new.level == .hidden { return .overlayHide }
    if old.level == .hidden { return .overlayExpand }
    if new.level > old.level { return .overlayGrow }
    if new.level < old.level { return .overlayCollapse }
    return .overlayContentSwap
  }
}
