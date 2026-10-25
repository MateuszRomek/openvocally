import AppKit
import SwiftUI

// MARK: - Tokens

/// Copies of the DesignSystem motion tokens, so the lab builds without resolving OpenVocallyKit's
/// dependencies. Values match `Motion.swift`.
nonisolated enum Tokens {
  static let expand = Animation.spring(response: 0.42, dampingFraction: 0.8)
  static let grow = Animation.spring(response: 0.5, dampingFraction: 0.68)
  static let collapse = Animation.spring(response: 0.45, dampingFraction: 1)
  static let hide = Animation.spring(response: 0.22, dampingFraction: 1)
  static let swap = Animation.smooth(duration: 0.3)
  /// Exits are quicker than entries: closing and stepping back.
  static let close = Animation.spring(response: 0.25, dampingFraction: 1)
  /// Keyboard-triggered opening and closing, which should feel immediate.
  static let instant = Animation.spring(response: 0.15, dampingFraction: 1)
  /// The content's own settle while the shape reveals it: short, so text never visibly reflows.
  static let contentSettle = Animation.easeOut(duration: 0.15)
  static let label = Font.system(size: 12, weight: .medium)
  static let glyph = Font.system(size: 11, weight: .semibold)
  static let wing: CGFloat = 64
  static let wingInset: CGFloat = 10
  static let dropInset: CGFloat = 12
  static let panelWidth: CGFloat = 460
  static let peekWidth: CGFloat = 380
}

// MARK: - Agents

enum Provider: String, CaseIterable {
  case claude = "Claude Code"
  case codex = "Codex"

  var symbol: String {
    switch self {
    case .claude: "asterisk"
    case .codex: "terminal"
    }
  }
}

enum ApprovalKind: Equatable {
  case command
  case edit
  case fetch
}

struct Approval: Equatable {
  var kind: ApprovalKind = .command
  var title: String
  /// The exact command, path or URL, never shortened by the agent.
  var command: String
  /// Why the agent wants it, when the provider says (Codex's `reason`, Claude's tool description).
  var reason: String?
  /// The working folder for a command, or the size of an edit.
  var detail: String?

  var verbPhrase: String {
    switch kind {
    case .command: "run \(command.split(separator: "\n").first ?? "")"
    case .edit: "edit \(command)"
    case .fetch: "fetch \(command)"
    }
  }
}

enum ThreadState: Equatable {
  case idle
  case working(String)
  case needsYou(Approval)
  case failed(String)
  case done(String)

  /// What the closed notch shows first.
  var rank: Int {
    switch self {
    case .needsYou: 4
    case .failed: 3
    case .working: 2
    case .done: 1
    case .idle: 0
    }
  }

  var word: String {
    switch self {
    case .idle: "Idle"
    case .working: "Working"
    case .needsYou: "Needs you"
    case .failed: "Failed"
    case .done: "Done"
    }
  }
}

enum Role: Equatable {
  case user
  case agent
  /// A tool step, shown collapsed to one line.
  case tool
}

struct Message: Identifiable, Equatable {
  let id: Int
  var role: Role
  var text: String
}

struct AgentThread: Identifiable, Equatable {
  let id: Int
  var title: String
  var project: String
  var provider: Provider
  var state: ThreadState
  var messages: [Message]
  var updated: Date
  /// False from the moment a thread finishes until you peek at it or open it.
  var seen = true

  /// Whether the closed notch shows this thread. Working is ambient and never shows there:
  /// only what needs you, what failed, and a finished reply you haven't looked at.
  var wantsAttention: Bool {
    switch state {
    case .needsYou, .failed: true
    case .done: !seen
    case .working, .idle: false
    }
  }

  /// The newest thing the agent or you said, for one-line previews.
  var lastLine: String {
    let last = messages.last { $0.role != .tool }
    let line = last?.text.split(separator: "\n").first.map(String.init) ?? ""
    return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
  }

  var lastReply: Message? { messages.last { $0.role == .agent } }
}

enum Dictation: Equatable {
  case off
  /// `thread` is nil for plain dictation, which pastes.
  case recording(thread: Int?)
  case transcribing(thread: Int?)
  case pasted
  case sent(thread: Int)
  /// What was said while an approval waited went to the agent as the reason for denying it.
  case deniedWithReason(thread: Int)
}

enum Level: Equatable {
  case idle
  case status
  case peek
  /// An approval the notch grew to show on its own. Never takes keyboard focus.
  case approval
  case expanded
}

// MARK: - Options

enum DisplayScope: String, CaseIterable, Identifiable {
  case withMenuBar = "Every display with a menu bar"
  case all = "Every display"
  case pointer = "Display with the pointer"
  case main = "Main display"
  var id: Self { self }
}

/// How a display without a notch draws the surface.
enum Backdrop: String, CaseIterable, Identifiable {
  case plain = "Notch, plain"
  case shoulders = "Notch, dark shoulders"
  case shadow = "Notch, drop shadow"
  case pill = "Pill below menu bar"
  var id: Self { self }
}

enum SimulatedHeight: String, CaseIterable, Identifiable {
  case menuBar = "Menu bar height"
  case macBook = "MacBook (32 pt)"
  var id: Self { self }
}

enum IdleOnNotchless: String, CaseIterable, Identifiable {
  case nothing = "Nothing"
  case resting = "Resting notch"
  var id: Self { self }
}

/// How far below the drawn shape the pointer still counts as on the notch, for hover only.
enum HoverReach: String, CaseIterable, Identifiable {
  case tight = "8 pt"
  case comfortable = "20 pt"
  case generous = "36 pt"
  var id: Self { self }

  var points: CGFloat {
    switch self {
    case .tight: 8
    case .comfortable: 20
    case .generous: 36
    }
  }
}

enum HoverBehavior: String, CaseIterable, Identifiable {
  case peek = "Peek, click opens"
  case open = "Open after 0.3 s"
  case none = "Click only"
  var id: Self { self }
}

enum CloseBehavior: String, CaseIterable, Identifiable {
  case mouseExit = "Pointer leaves"
  case clickOutside = "Esc or click outside"
  var id: Self { self }
}

enum WorkingIndicator: String, CaseIterable, Identifiable {
  case dot = "Still dot"
  case pulse = "Slow pulse"
  case spinner = "Spinner"
  var id: Self { self }
}

enum PanelLayout: String, CaseIterable, Identifiable {
  case drillIn = "List, then the thread"
  case preview = "List with the reply below"
  var id: Self { self }
}

/// How big a thread grows when you drill into it. The list stays at `Tokens.panelWidth`.
enum ThreadSize: String, CaseIterable, Identifiable {
  case compact = "Compact (460 pt)"
  case roomy = "Roomy (620 pt)"
  case large = "Large (760 pt)"
  var id: Self { self }

  var width: CGFloat {
    switch self {
    case .compact: 460
    case .roomy: 620
    case .large: 760
    }
  }

  /// The conversation's tallest height, as a share of the display's usable height.
  var heightShare: CGFloat {
    switch self {
    case .compact: 0.3
    case .roomy: 0.45
    case .large: 0.6
    }
  }
}

enum OpenMotion: String, CaseIterable, Identifiable {
  case grow = "overlayGrow (0.5, 0.68)"
  case critical = "Critically damped (0.4, 1.0)"
  case snappy = "Snappy (0.3, 0.9)"
  var id: Self { self }

  var animation: Animation {
    switch self {
    case .grow: Tokens.grow
    case .critical: .spring(response: 0.4, dampingFraction: 1)
    case .snappy: .spring(response: 0.3, dampingFraction: 0.9)
    }
  }
}

/// How the notch shows an approval that arrives while the panel is closed.
enum ApprovalArrival: String, CaseIterable, Identifiable {
  case mark = "Needs you mark only"
  case peek = "One line for 4 s"
  case card = "Card with buttons"
  var id: Self { self }
}

enum ApprovalQueue: String, CaseIterable, Identifiable {
  case oneAtATime = "One card, 1 of N"
  case stacked = "Front card, the rest stacked"
  case list = "Every card listed"
  var id: Self { self }
}

enum CommandLength: String, CaseIterable, Identifiable {
  case full = "In full, wrapped"
  case oneLine = "One line, Show all"
  var id: Self { self }
}

enum AllowPlacement: String, CaseIterable, Identifiable {
  case button = "Its own button"
  case menu = "Menu beside Allow"
  var id: Self { self }
}

enum CardLinger: String, CaseIterable, Identifiable {
  case untilAnswered = "Until answered"
  case shrinks = "Shrinks to the mark after 8 s"
  var id: Self { self }
}

/// Which thread agent mode speaks to while an approval card is showing.
enum VoiceTarget: String, CaseIterable, Identifiable {
  case card = "The thread on the card"
  case selected = "The selected thread"
  var id: Self { self }
}

// MARK: - Displays

typealias ScreenID = CGDirectDisplayID

extension NSScreen {
  var screenID: ScreenID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }

  /// With separate Spaces every display has its own menu bar; without, only the primary one does.
  /// Read from the setting, not the visible frame, so an auto-hidden menu bar still counts.
  var hasMenuBar: Bool {
    NSScreen.screensHaveSeparateSpaces || self == NSScreen.screens.first
  }

  var menuBarHeight: CGFloat {
    let height = frame.maxY - visibleFrame.maxY
    return height > 0 ? height : 24
  }
}

/// The notch the surface grows from on one display: the hardware one, or a simulated one.
struct NotchMetrics: Equatable {
  var size: CGSize
  /// Horizontal center in global screen coordinates.
  var centerX: CGFloat
  var isReal: Bool
  var menuBarHeight: CGFloat

  static func of(_ screen: NSScreen, forceNotchless: Bool, simulated: SimulatedHeight) -> Self {
    let frame = screen.frame
    if !forceNotchless, screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
      let right = screen.auxiliaryTopRightArea
    {
      let width = frame.width - left.width - right.width
      return Self(
        size: CGSize(width: width, height: screen.safeAreaInsets.top),
        centerX: frame.minX + left.width + width / 2, isReal: true,
        menuBarHeight: screen.safeAreaInsets.top)
    }
    let height: CGFloat =
      switch simulated {
      case .menuBar: screen.menuBarHeight
      case .macBook: 32
      }
    return Self(
      size: CGSize(width: 185, height: height), centerX: frame.midX, isReal: false,
      menuBarHeight: screen.menuBarHeight)
  }
}
