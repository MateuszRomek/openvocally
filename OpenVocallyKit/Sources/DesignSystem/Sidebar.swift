import AppKit
import SwiftUI

/// The bottom of a sidebar, under its List: a hairline, then rows such as Settings that stay
/// in view however long the list grows.
public struct SidebarFooter<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    VStack(spacing: Space.xs.points) {
      Divider().padding(.horizontal, Space.xs)
      content
    }
    // Lines the rows up with the SidebarRows the List insets 16 pt from the sidebar edge.
    .padding(.horizontal, Space.l)
    .padding(.bottom, Space.s)
  }
}

/// A sidebar row, in the List or in a `SidebarFooter`. Selected, it sits on a faint
/// `selection` pill and keeps its own text color, so the List never draws AppKit's selection,
/// which turns into a filled accent row whenever the List has focus.
public struct SidebarRow<Accessory: View>: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void
  let accessory: Accessory

  public init(
    _ title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isSelected = isSelected
    self.action = action
    self.accessory = accessory()
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: Space.s.points) {
        Image(systemName: systemImage)
          .imageScale(.large)
          .foregroundStyle(.secondary)
          .frame(width: Space.xl.points)
        Text(title)
        Spacer(minLength: 0)
        accessory
      }
      .padding(.horizontal, Space.s)
      // Matches the List's 32 pt row height.
      .padding(.vertical, Space.xs.points + Space.xxs.points)
      .background(isSelected ? SemanticColor.selection.color : .clear, in: Radius.small.shape)
      .contentShape(Radius.small.shape)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension SidebarRow where Accessory == EmptyView {
  public init(_ title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) {
    self.init(title, systemImage: systemImage, isSelected: isSelected, action: action) { EmptyView() }
  }
}

/// A calm notice in a `SidebarFooter`, such as an update waiting to install: an `accent` icon,
/// a title and a secondary detail. It is the one highlight on screen, so it never uses
/// `attention`. Insert it with `SidebarNotice.entrance(reduceMotion:)` and `Motion.windowReveal`.
public struct SidebarNotice: View {
  let title: String
  let detail: String?
  let systemImage: String
  let action: () -> Void

  public init(_ title: String, detail: String? = nil, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: Space.s.points) {
        Image(systemName: systemImage)
          .imageScale(.large)
          .foregroundStyle(SemanticColor.accent.color)
          .frame(width: Space.xl.points)
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
        if let detail {
          Text(detail)
            .textStyle(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, Space.s)
      .padding(.vertical, Space.xs.points + Space.xxs.points)
      .background(SemanticColor.selection.color, in: Radius.small.shape)
      .contentShape(Radius.small.shape)
    }
    .buttonStyle(.plain)
    .accessibilityValue(detail ?? "")
  }

  /// Fades in from a few points below; under Reduce Motion it appears with no movement.
  @MainActor public static func entrance(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .identity : .opacity.combined(with: .offset(y: Space.xs.points))
  }
}
