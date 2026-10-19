import SwiftUI

/// The state of one thing the app depends on, such as a permission or the speech model.
public enum Status: String, CaseIterable, Sendable {
  case ok
  case progress
  /// The user can fix it, such as a missing permission.
  case attention
  /// Something broke that the user can only retry.
  case failed

  /// The SF Symbol, or nil for `progress`, which shows a spinner.
  public var symbol: String? {
    switch self {
    case .ok: "checkmark.circle.fill"
    case .progress: nil
    case .attention: "exclamationmark.circle.fill"
    case .failed: "xmark.circle.fill"
    }
  }

  public var color: SemanticColor? {
    switch self {
    case .ok: .success
    case .progress: nil
    case .attention: .attention
    case .failed: .destructive
    }
  }
}

public struct StatusIcon: View {
  /// The icon column, so lines under a row can align with its text.
  public static let width: CGFloat = 18

  let status: Status

  public init(_ status: Status) {
    self.status = status
  }

  public var body: some View {
    Group {
      if let symbol = status.symbol, let color = status.color {
        Image(systemName: symbol).foregroundStyle(.token(color))
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(width: Self.width)
    .accessibilityHidden(true)
  }
}

/// A title, a one-line explanation and a status icon, for checklists like readiness.
public struct StatusRow: View {
  /// Leading inset that lines content up with a row's title.
  public static let textInset = StatusIcon.width + Space.s.points

  let title: String
  let detail: String
  let status: Status

  public init(title: String, detail: String, status: Status) {
    self.title = title
    self.detail = detail
    self.status = status
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.s.points) {
      StatusIcon(status)
      VStack(alignment: .leading, spacing: Space.xxs.points) {
        Text(title).textStyle(.body).fontWeight(.medium)
        Text(detail)
          .textStyle(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
