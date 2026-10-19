import SwiftUI

/// A keyboard shortcut drawn as a key, such as "⌘V" or "fn". A pressed cap, such as a key
/// held while recording a shortcut, sits slightly smaller (`Motion.keyCap`); under Reduce
/// Motion it dims instead. An empty string draws a blank cap for "waiting for a key".
///
/// `.large` draws one physical key with a visible side, for a page whose main action is a
/// shortcut. Pressed, it sits down onto its side at once: it follows a real key press, and the
/// design system never animates a keyboard shortcut.
public struct KeyCap: View {
  public enum Size: Sendable {
    case inline
    case large
  }

  let keys: String
  let isPressed: Bool
  let size: Size

  public init(_ keys: String, isPressed: Bool = false, size: Size = .inline) {
    self.keys = keys
    self.isPressed = isPressed
    self.size = size
  }

  public var body: some View {
    switch size {
    case .inline: InlineCap(keys: keys, isPressed: isPressed)
    case .large: LargeCap(keys: keys, isPressed: isPressed)
    }
  }
}

private struct InlineCap: View {
  let keys: String
  let isPressed: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text(keys.isEmpty ? "⌘" : keys)
      .textStyle(.overlayGlyph)
      .opacity(keys.isEmpty ? 0 : 1)
      .padding(.horizontal, Space.xs)
      .padding(.vertical, Space.xxs)
      .background(.token(.contentBackground), in: Radius.small.shape)
      .overlay(Radius.small.shape.stroke(.token(.separator)))
      .scaleEffect(isPressed && !reduceMotion ? Motion.pressScale : 1)
      .opacity(isPressed && reduceMotion ? Motion.pressDim : 1)
      .motion(.keyCap, value: isPressed)
  }
}

/// Drawn like a Mac keyboard: a modifier shows its symbol in the top corner and its name in the
/// bottom one, Space is wide, and any other key is one centered glyph. Disabled, the legends
/// fade to tertiary.
private struct LargeCap: View {
  let keys: String
  let isPressed: Bool
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let legend = Legend(keys)
    content(legend)
      .foregroundStyle(isEnabled ? .primary : .tertiary)
      .padding(Space.s)
      .frame(width: legend.width, height: Self.side)
      .background(.token(.contentBackground), in: Radius.card.shape)
      .overlay(
        Radius.card.shape.strokeBorder(.token(.separator), lineWidth: contrast == .increased ? 1.5 : 1)
      )
      .offset(y: isPressed ? Self.depth : 0)
      .background {
        Radius.card.shape.fill(.token(.separator)).offset(y: Self.depth)
      }
      .padding(.bottom, Self.depth)
  }

  @ViewBuilder private func content(_ legend: Legend) -> some View {
    switch legend {
    case .glyph(let glyph):
      Text(glyph).textStyle(.title1).fontWeight(.medium)
        .frame(minWidth: Self.side - 2 * Space.s.points, maxHeight: .infinity)
    case .named(let symbol, let name, _):
      VStack(alignment: .leading) {
        HStack {
          Spacer(minLength: 0)
          symbol.textStyle(.title3)
        }
        Spacer(minLength: 0)
        Text(name).textStyle(.caption)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }

  nonisolated static let side: CGFloat = 64
  /// How far the key travels when pressed, and how much of its side shows at rest.
  static let depth: CGFloat = 4

  private enum Legend {
    case glyph(String)
    case named(Text, String, width: CGFloat)

    init(_ keys: String) {
      let key = keys.replacing(#/^(Left|Right) /#, with: "")
      switch key {
      case "⌘": self = .named(Text("⌘"), "command", width: 84)
      case "⌥": self = .named(Text("⌥"), "option", width: 76)
      case "⌃": self = .named(Text("⌃"), "control", width: 76)
      case "⇧": self = .named(Text("⇧"), "shift", width: 84)
      case "Fn", "fn": self = .named(Text(Image(systemName: "globe")), "fn", width: LargeCap.side)
      case "Space": self = .named(Text(""), "space", width: 208)
      case "": self = .glyph(" ")
      default: self = .glyph(key)
      }
    }

    var width: CGFloat? {
      switch self {
      case .glyph: nil
      case .named(_, _, let width): width
      }
    }
  }
}
