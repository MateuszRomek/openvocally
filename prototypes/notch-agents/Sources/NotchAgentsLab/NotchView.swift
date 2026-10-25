import AppKit
import SwiftUI

/// What one display's panel draws. One shape stays mounted at every level, so idle, status, peek
/// and the open panel are the same object growing and shrinking.
struct NotchRoot: View {
  let lab: Lab
  let display: DisplayState

  var body: some View {
    let metrics = display.metrics
    let pill = !metrics.isReal && lab.backdrop == .pill
    VStack(spacing: 0) {
      let level = lab.level(on: display.screen)
      SurfaceView(lab: lab, metrics: metrics, level: level, pill: pill) {
        // A click on an approval card opens the thread that asked.
        lab.open(
          .expanded, on: display.screen.screenID, thread: level == .approval ? lab.frontApproval : nil)
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [display] rect in
        display.shapeRect = rect
      }
      .overlay(alignment: .top) {
        if lab.showHoverZone {
          // The hover zone from `DisplayHost.hoverRect`, drawn for tuning: 12 pt each side and
          // the chosen reach below.
          Rectangle()
            .strokeBorder(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .padding(.horizontal, -12)
            .padding(.bottom, -lab.hoverReach.points)
            .allowsHitTesting(false)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.top, pill ? metrics.menuBarHeight + 6 : 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, .dark)
  }
}

struct SurfaceView: View {
  let lab: Lab
  let metrics: NotchMetrics
  let level: Level
  let pill: Bool
  let openPanel: () -> Void
  /// The part of the content the black shape shows. It springs on the lab's latest motion while
  /// the content itself already has its final layout.
  @State private var revealed: CGSize = .zero
  /// Counts the times an attention mark or an unseen Done first showed in the closed notch, so
  /// its one-time signal plays once per arrival.
  @State private var signal = 0
  @State private var glow: Double = 0
  @State private var glowTint: Color = .orange

  var body: some View {
    let shape = SurfaceShape(radii: radii, visible: revealed)
    ZStack(alignment: .top) {
      switch level {
      case .idle:
        Color.clear.frame(width: 0, height: 0)
      case .status where lab.showsAmbient && lab.ambient == .lip:
        AmbientLip(width: metrics.size.width, height: metrics.size.height, still: lab.reduceMotion)
          .transition(.blurReplace)
      case .status:
        VStack(spacing: 0) {
          StatusRow(lab: lab, metrics: metrics, pill: pill, signal: signal)
          if let target = speakingTo { DropLine(text: "Speaking to \(target)") }
          if case .deniedWithReason = lab.dictation { DropLine(text: "Denied. What you said went as the reason.") }
          if case .answeredBySpeech = lab.dictation { DropLine(text: "What you said went as the answer.") }
        }
        .transition(.blurReplace)
      case .peek:
        VStack(spacing: 0) {
          StatusRow(lab: lab, metrics: metrics, pill: pill)
          DropLine(text: peekText)
        }
        .frame(minWidth: Tokens.peekWidth)
        .transition(.blurReplace)
      case .approval:
        VStack(spacing: 0) {
          StatusRow(lab: lab, metrics: metrics, pill: pill, signal: signal)
          ApprovalStack(lab: lab)
        }
        .frame(width: lab.arrival == .peek && !lab.keyRevealed ? nil : Tokens.panelWidth)
        .frame(minWidth: Tokens.peekWidth)
        .transition(.blurReplace)
      case .expanded:
        VStack(spacing: 0) {
          StatusRow(lab: lab, metrics: metrics, pill: pill)
          ThreadPanel(lab: lab)
        }
        .frame(width: lab.panelWidth)
        .transition(.blurReplace)
      }
    }
    .frame(minWidth: minSize.width, minHeight: minSize.height, alignment: .top)
    // The content takes its final size at once and only fades, so text never re-wraps while the
    // shape grows; the shape below does the moving.
    .transaction { if $0.animation != nil { $0.animation = Tokens.contentSettle } }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
      if revealed == .zero {
        revealed = size
      } else {
        withAnimation(lab.shapeMotion) { revealed = size }
      }
    }
    .clipShape(shape)
    .overlay {
      // A soft halo just outside the black edge: light, not motion, so Reduce Motion keeps it.
      shape.stroke(glowTint, lineWidth: 2).blur(radius: 5).opacity(glow).allowsHitTesting(false)
    }
    .background { backdrop(shape) }
    .onChange(of: attentionKey) { _, key in
      guard let key, level == .status || level == .approval else { return }
      signal += 1
      guard lab.attentionArrival == .glow, key.attention else { return }
      glowTint = key.tint
      Task {
        // Waits for the shape to grow first, so the glow lands on its final edge.
        try? await Task.sleep(for: .seconds(lab.reduceMotion ? 0.2 : 0.3))
        withAnimation(.easeOut(duration: 0.25)) { glow = 0.9 }
        try? await Task.sleep(for: .seconds(0.35))
        withAnimation(.easeOut(duration: 0.9)) { glow = 0 }
      }
    }
    .contentShape(shape)
    .onTapGesture { if level != .expanded { openPanel() } }
    .opacity(hidden ? 0 : 1)
    .scaleEffect(pill && hidden ? 0.9 : 1, anchor: .top)
  }

  @ViewBuilder private func backdrop(_ shape: SurfaceShape) -> some View {
    let fill = shape.fill(Color.black)
    if !metrics.isReal, !pill, lab.backdrop == .shoulders {
      fill.background(alignment: .top) {
        GeometryReader { proxy in
          let spread: CGFloat = 120
          Rectangle()
            .fill(Color.black)
            .mask {
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0),
                  .init(color: .black, location: spread / (proxy.size.width + 2 * spread)),
                  .init(color: .black, location: 1 - spread / (proxy.size.width + 2 * spread)),
                  .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: proxy.size.width + 2 * spread, height: metrics.menuBarHeight)
            .offset(x: -spread)
        }
      }
    } else if !metrics.isReal, !pill, lab.backdrop == .shadow {
      fill.shadow(color: .black.opacity(0.5), radius: 10, y: 3)
    } else if pill {
      fill
        .overlay { shape.stroke(Color.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    } else {
      fill
    }
  }

  /// A real notch hides inside the camera housing. A simulated one either rests where the
  /// housing would be or disappears.
  private var hidden: Bool {
    guard level == .idle else { return false }
    if metrics.isReal { return false }
    if pill { return true }
    return lab.idleOnNotchless == .nothing
  }

  private var minSize: CGSize {
    let notch = metrics.size
    switch level {
    case .idle:
      if pill { return CGSize(width: 120, height: 32) }
      if !metrics.isReal, lab.idleOnNotchless == .resting { return notch }
      return CGSize(width: notch.width - 4, height: notch.height - 2)
    case .status where lab.showsAmbient && lab.ambient == .lip && !pill:
      return CGSize(width: notch.width, height: notch.height + 5)
    case .status, .peek, .approval, .expanded:
      return pill
        ? CGSize(width: 120, height: 36)
        : CGSize(width: notch.width + 2 * Tokens.wing, height: notch.height)
    }
  }

  private var radii: SurfaceRadii {
    if pill {
      switch level {
      case .idle, .status: return SurfaceRadii(flare: 0, top: 18, bottom: 18)
      case .peek: return SurfaceRadii(flare: 0, top: 18, bottom: 20)
      case .approval: return SurfaceRadii(flare: 0, top: 22, bottom: 24)
      case .expanded: return SurfaceRadii(flare: 0, top: 22, bottom: 26)
      }
    }
    switch level {
    case .idle:
      return !metrics.isReal && lab.idleOnNotchless == .resting
        ? SurfaceRadii(flare: 6, top: 0, bottom: 10) : SurfaceRadii(flare: 0, top: 0, bottom: 10)
    case .status: return SurfaceRadii(flare: 6, top: 0, bottom: 12)
    case .peek: return SurfaceRadii(flare: 10, top: 0, bottom: 20)
    case .approval: return SurfaceRadii(flare: 12, top: 0, bottom: 24)
    case .expanded: return SurfaceRadii(flare: 14, top: 0, bottom: 26)
    }
  }

  /// The mark the closed strip shows, while dictation isn't using it. Nil when it shows none.
  private var attentionKey: AttentionKey? {
    guard lab.dictation == .off, let thread = lab.primaryThread else { return nil }
    switch thread.state {
    case .needsYou: return AttentionKey(thread: thread.id, word: thread.state.word, attention: true, tint: .orange)
    case .failed: return AttentionKey(thread: thread.id, word: thread.state.word, attention: true, tint: lab.failedTint.color)
    default: return AttentionKey(thread: thread.id, word: thread.state.word, attention: false, tint: .white)
    }
  }

  private var speakingTo: String? {
    guard lab.showTarget, case .recording(let id?) = lab.dictation else { return nil }
    return lab.thread(id)?.title
  }

  private var peekText: String {
    guard let thread = lab.primaryThread else {
      // A peek is a deliberate look, so it can name the ambient work the closed notch hides.
      let working = lab.threads.filter { if case .working = $0.state { true } else { false } }.count
      return switch working {
      case 0: "Nothing running"
      case 1: "1 thread working"
      default: "\(working) threads working"
      }
    }
    switch thread.state {
    case .needsYou(let approval): return "\(thread.title) wants to \(approval.verbPhrase)"
    case .working(let step): return "\(thread.title) · \(step)"
    case .failed(let text): return "\(thread.title) · \(text)"
    case .done: return "\(thread.title) · \(thread.lastLine)"
    case .idle: return thread.title
    }
  }
}

struct AttentionKey: Equatable {
  var thread: Int
  var word: String
  var attention: Bool
  var tint: Color
}

/// The ambient working signal: the notch drops a few points below the camera and a faint light
/// drifts along that lip. Under Reduce Motion the light holds still.
private struct AmbientLip: View {
  let width: CGFloat
  let height: CGFloat
  let still: Bool

  var body: some View {
    let track = width * 0.42
    ZStack(alignment: .bottom) {
      Color.clear.frame(width: width, height: height + 5)
      Capsule().fill(Color.white.opacity(0.14)).frame(width: track, height: 2)
        .overlay {
          if still {
            Capsule().fill(Color.white.opacity(0.22))
          } else {
            TimelineView(.animation) { context in
              let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
              LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.6), location: 0.5), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: track * 0.45)
                .offset(x: (CGFloat(t) * 1.45 - 0.725) * track)
            }
            .clipShape(Capsule())
          }
        }
        .padding(.bottom, 2)
    }
  }
}

/// One line of text under the camera, for peek and the agent-mode target.
private struct DropLine: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Tokens.label)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, Tokens.dropInset)
      .padding(.top, 2)
      .padding(.bottom, Tokens.dropInset - 2)
      .frame(maxWidth: Tokens.panelWidth)
  }
}

// MARK: - Closed row

/// The row beside the camera. It never moves when the shape grows below it.
struct StatusRow: View {
  let lab: Lab
  let metrics: NotchMetrics
  let pill: Bool
  var signal = 0

  var body: some View {
    WingLayout(gap: pill ? 6 : metrics.size.width, minWing: pill ? 44 : Tokens.wing) {
      ZStack { leading }
      ZStack { trailing }
    }
    .frame(height: pill ? 36 : metrics.size.height)
    .padding(.horizontal, pill ? 6 : 0)
  }

  @ViewBuilder private var leading: some View {
    switch lab.dictation {
    case .recording(let thread), .transcribing(let thread):
      Glyph(
        symbol: thread.flatMap { lab.thread($0)?.provider.symbol } ?? "mic.fill",
        tint: isRecording ? .white : .secondary)
    case .pasted: Glyph(symbol: "checkmark", tint: .white)
    case .sent: Glyph(symbol: "arrow.up", tint: .white)
    case .deniedWithReason: Glyph(symbol: "xmark", tint: .white)
    case .answeredBySpeech: Glyph(symbol: "arrow.up", tint: .white)
    case .off:
      if let thread = lab.primaryThread {
        Glyph(symbol: thread.provider.symbol, tint: .white).id(thread.id)
      } else if lab.showsAmbient, let thread = lab.workingThreads.first {
        // Ambient: the working thread's provider, dimmed, so it reads as background.
        Glyph(symbol: lab.workingThreads.count == 1 ? thread.provider.symbol : "square.stack", tint: .secondary)
      } else {
        Glyph(symbol: "waveform", tint: .secondary)
      }
    }
  }

  @ViewBuilder private var trailing: some View {
    switch lab.dictation {
    case .recording: Bars(levels: lab.levels, live: true)
    case .transcribing: Bars(levels: lab.levels, live: false)
    case .pasted: Word(text: "Pasted")
    case .sent: Word(text: "Sent")
    case .deniedWithReason: Word(text: "Denied")
    case .answeredBySpeech: Word(text: "Answered")
    case .off:
      if let thread = lab.primaryThread {
        HStack(spacing: 6) {
          StateMark(
            state: thread.state, indicator: lab.working, signal: signal, arrival: lab.attentionArrival,
            doneMark: lab.doneMark, failedTint: lab.failedTint, reduceMotion: lab.reduceMotion)
          if lab.attentionThreads.count > 1 { Badge(count: lab.attentionThreads.count) }
        }
      } else if lab.showsAmbient {
        HStack(spacing: 5) {
          WorkingMark(indicator: lab.ambient == .breathingDot && !lab.reduceMotion ? .pulse : .dot)
          if lab.workingThreads.count > 1 {
            Text("\(lab.workingThreads.count)").font(Tokens.label.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        .transition(.blurReplace)
      } else {
        Word(text: "\(lab.threads.count) threads")
      }
    }
  }

  private var isRecording: Bool {
    if case .recording = lab.dictation { return true }
    return false
  }
}

/// Two subviews, the leading and the trailing wing, each centered in an equal-width wing.
nonisolated struct WingLayout: Layout {
  let gap: CGFloat
  let minWing: CGFloat

  private func wing(_ subviews: Subviews) -> CGFloat {
    let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    return max(minWing, widest + 2 * Tokens.wingInset)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: gap + 2 * wing(subviews), height: proposal.height ?? 32)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let wing = wing(subviews)
    for (index, subview) in subviews.enumerated() {
      let minX = index == 0 ? bounds.minX : bounds.minX + wing + gap
      subview.place(
        at: CGPoint(x: minX + wing / 2, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
  }
}

struct Glyph: View {
  let symbol: String
  let tint: Color

  var body: some View {
    Image(systemName: symbol)
      .font(Tokens.glyph)
      .foregroundStyle(tint)
      .frame(width: 14, height: 14)
      .transition(.blurReplace)
  }
}

struct Word: View {
  let text: String

  var body: some View {
    Text(text).font(Tokens.label).foregroundStyle(.white).transition(.blurReplace)
  }
}

struct Badge: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.system(size: 10, weight: .semibold).monospacedDigit())
      .foregroundStyle(.black)
      .padding(.horizontal, 5)
      .frame(minWidth: 16, minHeight: 16)
      .background(Capsule().fill(Color.white.opacity(0.85)))
      .contentTransition(.numericText())
  }
}

/// The thread's state in the closed row and the list. Needs you is the one colored state.
struct StateMark: View {
  let state: ThreadState
  let indicator: WorkingIndicator
  var showsWord = true
  /// Changes once each time this mark first shows in the closed notch.
  var signal = 0
  var arrival: AttentionArrival = .grow
  var doneMark: DoneMark = .check
  var failedTint: FailedTint = .orange
  var reduceMotion = false

  var body: some View {
    HStack(spacing: 5) {
      switch state {
      case .working:
        WorkingMark(indicator: indicator)
      case .needsYou:
        Circle().fill(Color.orange).frame(width: 6, height: 6)
          .keyframeAnimator(initialValue: 1.0, trigger: pulses ? signal : 0) { dot, scale in
            dot.scaleEffect(scale)
          } keyframes: { _ in
            KeyframeTrack {
              CubicKeyframe(1.8, duration: 0.22)
              CubicKeyframe(1, duration: 0.3)
              CubicKeyframe(1.8, duration: 0.22)
              CubicKeyframe(1, duration: 0.3)
            }
          }
      case .failed:
        Image(systemName: failedTint == .white ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.system(size: 9)).foregroundStyle(failedTint.color)
      case .done:
        switch doneMark {
        case .dot: Circle().fill(Color.white).frame(width: 6, height: 6)
        case .check, .glint:
          Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
      case .idle:
        EmptyView()
      }
      if showsWord {
        Text(state.word)
          .font(Tokens.label)
          .foregroundStyle(wordTint)
      }
    }
    .overlay {
      if glints {
        // One light sweep across the mark, masked to the glyph and the word.
        GeometryReader { proxy in
          let width = proxy.size.width
          LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.5), .init(color: .clear, location: 1)],
            startPoint: .leading, endPoint: .trailing)
            .frame(width: width * 0.5)
            .keyframeAnimator(initialValue: -0.6, trigger: signal) { light, x in
              light.offset(x: x * width)
            } keyframes: { _ in
              KeyframeTrack {
                LinearKeyframe(-0.6, duration: 0.3)
                CubicKeyframe(1.1, duration: 0.7)
              }
            }
        }
        .mask { HStack(spacing: 5) { content } }
        .allowsHitTesting(false)
      }
    }
    .transition(.blurReplace)
    .id(state.word)
  }

  /// A copy of the glyph and word for the glint's mask.
  @ViewBuilder private var content: some View {
    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
    Text(state.word).font(Tokens.label)
  }

  private var pulses: Bool { arrival == .pulse && !reduceMotion }

  private var glints: Bool {
    guard case .done = state, doneMark == .glint, !reduceMotion, signal > 0 else { return false }
    return true
  }

  private var wordTint: Color {
    switch state {
    case .needsYou: .orange
    case .failed: failedTint.color
    default: .white
    }
  }

  private var isAttention: Bool {
    switch state {
    case .needsYou, .failed: true
    default: false
    }
  }
}

struct WorkingMark: View {
  let indicator: WorkingIndicator
  @State private var dim = false

  var body: some View {
    switch indicator {
    case .dot:
      Circle().fill(Color.white.opacity(0.7)).frame(width: 6, height: 6)
    case .pulse:
      Circle().fill(Color.white).frame(width: 6, height: 6)
        .opacity(dim ? 0.3 : 0.9)
        .onAppear {
          withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
        }
    case .spinner:
      ProgressView().controlSize(.mini).frame(width: 10, height: 10)
    }
  }
}

struct Bars: View {
  let levels: [CGFloat]
  let live: Bool

  var body: some View {
    HStack(spacing: 2) {
      ForEach(levels.indices, id: \.self) { index in
        Capsule()
          .fill(Color.white.opacity(live ? 1 : 0.45))
          .frame(width: 2, height: live ? 3 + 13 * levels[index] : 3)
      }
    }
    .frame(height: 16)
    .transition(.blurReplace)
  }
}

// MARK: - Shape

nonisolated struct SurfaceRadii: Equatable {
  /// The outward curve where a notch meets the screen edge. Zero for the pill.
  var flare: CGFloat
  /// The pill's top corners. Zero for the notch, which is square against the screen edge.
  var top: CGFloat
  var bottom: CGFloat
}

nonisolated struct SurfaceShape: Shape {
  var radii: SurfaceRadii
  /// The drawn size, centered on the top edge of the frame. Zero draws the whole frame.
  var visible: CGSize

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
    get {
      AnimatablePair(
        AnimatablePair(visible.width, visible.height),
        AnimatablePair(radii.flare, AnimatablePair(radii.top, radii.bottom)))
    }
    set {
      visible = CGSize(width: newValue.first.first, height: newValue.first.second)
      radii = SurfaceRadii(
        flare: newValue.second.first, top: newValue.second.second.first, bottom: newValue.second.second.second)
    }
  }

  func path(in frame: CGRect) -> Path {
    let r =
      visible == .zero
      ? frame
      : CGRect(
        x: frame.midX - visible.width / 2, y: frame.minY, width: visible.width, height: visible.height)
    let flare = min(radii.flare, r.height / 2)
    let top = min(radii.top, r.height / 2, r.width / 2)
    let bottom = max(0, min(radii.bottom, r.height - max(flare, top), r.width / 2))
    var path = Path()
    path.move(to: CGPoint(x: r.minX - flare, y: r.minY))
    if flare > 0 {
      path.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + flare), control: CGPoint(x: r.minX, y: r.minY))
    } else {
      path.move(to: CGPoint(x: r.minX + top, y: r.minY))
      path.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + top), control: CGPoint(x: r.minX, y: r.minY))
    }
    path.addLine(to: CGPoint(x: r.minX, y: r.maxY - bottom))
    path.addQuadCurve(to: CGPoint(x: r.minX + bottom, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
    path.addLine(to: CGPoint(x: r.maxX - bottom, y: r.maxY))
    path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - bottom), control: CGPoint(x: r.maxX, y: r.maxY))
    if flare > 0 {
      path.addLine(to: CGPoint(x: r.maxX, y: r.minY + flare))
      path.addQuadCurve(to: CGPoint(x: r.maxX + flare, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
    } else {
      path.addLine(to: CGPoint(x: r.maxX, y: r.minY + top))
      path.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
    }
    path.closeSubpath()
    return path
  }
}
