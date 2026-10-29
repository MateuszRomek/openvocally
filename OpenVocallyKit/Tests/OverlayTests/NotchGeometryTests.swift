import Foundation
import Testing

@testable import Overlay

struct NotchGeometryTests {
  /// A left Dock 100 pt wide and a menu bar shrink the work area.
  static let screen = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1540, height: 925),
    visibleFrame: CGRect(x: 100, y: 50, width: 1440, height: 850))

  static let notched = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085), safeAreaTop: 32,
    auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
    auxiliaryTopRight: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32))

  static func screen(
    x: CGFloat = 0, width: CGFloat, height: CGFloat, notch: CGFloat, notchMidX: CGFloat? = nil,
    safeTop: CGFloat = 32, auxiliaryOrigin: CGFloat? = nil
  ) -> ScreenGeometry {
    let mid = notchMidX ?? x + width / 2
    let shift = (auxiliaryOrigin ?? x) - x
    return ScreenGeometry(
      frame: CGRect(x: x, y: 0, width: width, height: height),
      visibleFrame: CGRect(x: x, y: 0, width: width, height: height - safeTop),
      safeAreaTop: safeTop,
      auxiliaryTopLeft: CGRect(
        x: x + shift, y: height - safeTop, width: mid - notch / 2 - x, height: safeTop),
      auxiliaryTopRight: CGRect(
        x: mid + notch / 2 + shift, y: height - safeTop, width: x + width - mid - notch / 2,
        height: safeTop))
  }

  @Test func `the 16 inch notch is 185 by 32, centred at 864`() throws {
    let notch = try #require(NotchGeometry(Self.notched))
    #expect(notch.size == CGSize(width: 185, height: 32))
    #expect(notch.midX == 864)
    #expect(notch.hiddenSize == CGSize(width: 181, height: 30))
  }

  @Test func `a 14 inch screen reads its own notch`() throws {
    let notch = try #require(NotchGeometry(Self.screen(width: 1512, height: 982, notch: 185)))
    #expect(notch.size == CGSize(width: 185, height: 32))
    #expect(notch.midX == 756)
  }

  @Test func `a second display finds its notch from global or local areas`() throws {
    let global = try #require(NotchGeometry(Self.screen(x: 1728, width: 1512, height: 982, notch: 185)))
    let local = try #require(
      NotchGeometry(Self.screen(x: 1728, width: 1512, height: 982, notch: 185, auxiliaryOrigin: 0)))
    #expect(global.midX == 2484)
    #expect(local == global)
  }

  @Test func `an off-centre notch follows the auxiliary areas`() throws {
    let notch = try #require(
      NotchGeometry(Self.screen(width: 1512, height: 982, notch: 185, notchMidX: 700)))
    #expect(notch.midX == 700)
  }

  @Test func `a display without a safe area or an auxiliary area has no notch`() {
    #expect(NotchGeometry(Self.screen(width: 1512, height: 982, notch: 185, safeTop: 0)) == nil)
    var screen = Self.screen(width: 1512, height: 982, notch: 185)
    screen.auxiliaryTopRight = nil
    #expect(NotchGeometry(screen) == nil)
    #expect(NotchGeometry(Self.screen) == nil)
  }
}
