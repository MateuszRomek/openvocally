import SwiftUI

/// A one-off celebration: a burst of confetti from the bottom center each time `trigger`
/// changes. It draws nothing and its timeline stays paused between bursts, so an idle view
/// costs nothing. Festive colors by default, a one-off exception to the monochrome brand.
/// No particles under Reduce Motion.
public struct ConfettiBurst<Trigger: Equatable>: View {
  let trigger: Trigger
  let palette: [Color]
  @State private var burst: Burst?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct Burst: Equatable {
    let start: Date
    let field: ConfettiField
  }

  public init(trigger: Trigger, palette: [Color] = Self.festive) {
    self.trigger = trigger
    self.palette = palette.isEmpty ? Self.festive : palette
  }

  /// Ten vivid system hues, so the burst reads as a party.
  public static var festive: [Color] {
    [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .indigo, .purple, .pink]
  }

  public var body: some View {
    TimelineView(.animation(paused: burst == nil)) { context in
      Canvas { canvas, size in
        guard let burst else { return }
        let time = context.date.timeIntervalSince(burst.start)
        for piece in burst.field.pieces(at: time, in: size) {
          draw(piece, in: &canvas)
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onChange(of: trigger) {
      guard !reduceMotion else { return }
      let seed = (burst?.field.seed ?? 0) &+ 1
      burst = Burst(start: .now, field: ConfettiField(seed: seed))
    }
    .task(id: burst) {
      guard let burst else { return }
      try? await Task.sleep(for: .seconds(burst.field.lifetime))
      if !Task.isCancelled { self.burst = nil }
    }
  }

  private func draw(_ piece: ConfettiField.Piece, in canvas: inout GraphicsContext) {
    var context = canvas
    context.opacity = piece.opacity
    context.translateBy(x: piece.position.x, y: piece.position.y)
    context.rotate(by: .radians(piece.rotation))
    context.scaleBy(x: 1, y: piece.flip)
    let size = piece.size
    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let path: Path =
      switch piece.shape {
      case .rectangle: Path(rect)
      case .capsule: Path(roundedRect: rect, cornerRadius: min(size.width, size.height) / 2)
      case .circle:
        Path(ellipseIn: CGRect(x: -size.width / 2, y: -size.width / 2, width: size.width, height: size.width))
      }
    context.fill(path, with: .color(palette[piece.colorIndex % palette.count]))
  }
}

/// The math of one confetti burst, apart from drawing: every piece's launch comes from a
/// seeded generator, and its place at any time follows from a closed form (gravity with
/// linear drag), so a burst replays the same for the same seed.
struct ConfettiField: Equatable, Sendable {
  enum Shape: CaseIterable, Sendable {
    case rectangle
    case capsule
    case circle
  }

  struct Piece: Equatable, Sendable {
    let position: CGPoint
    /// Radians.
    let rotation: Double
    /// -1 to 1: the piece tumbling, drawn as a vertical squash.
    let flip: Double
    let opacity: Double
    let size: CGSize
    let shape: Shape
    let colorIndex: Int
  }

  struct Launch: Equatable, Sendable {
    /// Velocity in heights per second; y points down.
    let velocity: CGVector
    let spin: Double
    let tumble: Double
    let rotation: Double
    let life: Double
    let size: CGSize
    let shape: Shape
    let colorIndex: Int
  }

  let seed: UInt64
  let launches: [Launch]

  /// The longest a piece lives, in seconds. Nothing draws after it.
  var lifetime: Double { Self.maxLife }

  static let maxLife = 2.2
  static let gravity = 1.9
  static let drag = 1.4
  /// Color slots a piece picks from. 60 divides evenly by palettes of 2 to 6 and 10 colors.
  static let colorSlots = 60

  init(seed: UInt64, count: Int = 80) {
    self.seed = seed
    var random = SplitMix64(seed: seed)
    launches = (0..<count).map { _ in
      let angle = random.next(in: -0.6...0.6) - Double.pi / 2
      let speed = random.next(in: 1.5...2.6)
      return Launch(
        velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
        spin: random.next(in: -9...9),
        tumble: random.next(in: 4...12),
        rotation: random.next(in: 0...(2 * Double.pi)),
        life: random.next(in: 1.5...Self.maxLife),
        size: CGSize(width: random.next(in: 5...9), height: random.next(in: 3...6)),
        shape: Shape.allCases[Int(random.next(in: 0...2.999))],
        colorIndex: Int(random.next(in: 0...(Double(Self.colorSlots) - 0.001))))
    }
  }

  /// The pieces still alive `time` seconds after the burst, placed in a canvas of `size`.
  func pieces(at time: Double, in size: CGSize) -> [Piece] {
    guard time >= 0 else { return [] }
    let scale = size.height
    let origin = CGPoint(x: size.width / 2, y: size.height)
    let decay = (1 - exp(-Self.drag * time)) / Self.drag
    return launches.compactMap { launch in
      guard time < launch.life else { return nil }
      let terminal = Self.gravity / Self.drag
      let x = launch.velocity.dx * decay
      let y = terminal * time + (launch.velocity.dy - terminal) * decay
      let fadeStart = launch.life * 0.7
      let opacity = time < fadeStart ? 1 : max(0, 1 - (time - fadeStart) / (launch.life - fadeStart))
      return Piece(
        position: CGPoint(x: origin.x + x * scale, y: origin.y + y * scale),
        rotation: launch.rotation + launch.spin * time,
        flip: cos(launch.tumble * time),
        opacity: opacity,
        size: launch.size,
        shape: launch.shape,
        colorIndex: launch.colorIndex)
    }
  }
}

/// A small deterministic generator, so a seed always gives the same burst.
struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func next(in range: ClosedRange<Double>) -> Double {
    let unit = Double(next() >> 11) / Double(1 << 53)
    return range.lowerBound + unit * (range.upperBound - range.lowerBound)
  }
}
