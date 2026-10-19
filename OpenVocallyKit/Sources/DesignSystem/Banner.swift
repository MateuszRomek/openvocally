import SwiftUI

/// A message in a window that the user should read before going on.
public struct Banner<Actions: View>: View {
  public enum Tone: String, CaseIterable, Sendable {
    case info
    /// The user needs to do something, such as grant a permission.
    case attention

    var symbol: String {
      switch self {
      case .info: "info.circle.fill"
      case .attention: "exclamationmark.triangle.fill"
      }
    }
  }

  let tone: Tone
  let title: String
  let message: String
  let actions: Actions

  public init(
    tone: Tone, title: String, message: String, @ViewBuilder actions: () -> Actions
  ) {
    self.tone = tone
    self.title = title
    self.message = message
    self.actions = actions()
  }

  public var body: some View {
    Card {
      HStack(alignment: .firstTextBaseline, spacing: Space.s.points) {
        Image(systemName: tone.symbol)
          .foregroundStyle(tone == .attention ? .token(.attention) : .secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Space.s.points) {
          VStack(alignment: .leading, spacing: Space.xxs.points) {
            Text(title).textStyle(.body).fontWeight(.medium)
            Text(message)
              .textStyle(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: Space.s.points) { actions }
        }
      }
    }
  }
}

extension Banner where Actions == EmptyView {
  public init(tone: Tone, title: String, message: String) {
    self.init(tone: tone, title: title, message: message) { EmptyView() }
  }
}
