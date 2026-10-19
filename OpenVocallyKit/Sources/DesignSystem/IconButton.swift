import SwiftUI

/// A quiet icon-only action that sits beside a `CopyButton`, such as Delete or Close in a detail
/// header. It shares the copy button's secondary symbol, press feedback and help tag, so a row of
/// actions reads as one set.
public struct IconButton: View {
  private let title: String
  private let systemImage: String
  private let action: () -> Void

  /// `title` is the help tag and the accessibility label.
  public init(_ title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(PressFeedbackStyle())
    .help(title)
  }
}
