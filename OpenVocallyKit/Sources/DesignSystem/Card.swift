import SwiftUI

/// Grouped content in the native macOS group box, for stats, charts and grouped lists.
public struct Card<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    GroupBox {
      content
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
