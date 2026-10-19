import CoreGraphics
import Testing

@testable import DesignSystem

@Test func `a seed replays the same burst`() {
  let size = CGSize(width: 560, height: 600)
  let first = ConfettiField(seed: 7).pieces(at: 0.5, in: size)
  #expect(first == ConfettiField(seed: 7).pieces(at: 0.5, in: size))
  #expect(first != ConfettiField(seed: 8).pieces(at: 0.5, in: size))
}

@Test func `pieces start at the bottom center and rise`() {
  let size = CGSize(width: 400, height: 300)
  let field = ConfettiField(seed: 1)
  let start = field.pieces(at: 0, in: size)
  #expect(start.count == 80)
  #expect(start.allSatisfy { $0.position == CGPoint(x: 200, y: 300) })
  let risen = field.pieces(at: 0.4, in: size)
  #expect(risen.allSatisfy { $0.position.y < 300 })
}

@Test func `every piece is gone after the lifetime`() {
  let field = ConfettiField(seed: 3)
  let size = CGSize(width: 100, height: 100)
  #expect(field.pieces(at: field.lifetime, in: size).isEmpty)
  #expect(field.pieces(at: field.lifetime + 1, in: size).isEmpty)
  #expect(field.pieces(at: -0.1, in: size).isEmpty)
}
