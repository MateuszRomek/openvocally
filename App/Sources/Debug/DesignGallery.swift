#if DEBUG
  import AppKit
  import DesignSystem
  import DictationCore
  import Overlay
  import SwiftUI

  /// Debug-only page that renders every design token under each appearance the app supports.
  /// Launch with `-designGallery YES` to open it at start, and add
  /// `-designGallerySection <name>` to show one section.
  struct DesignGallery: View {
    private static let appearances: [(title: String, name: NSAppearance.Name)] = [
      ("Light", .aqua),
      ("Dark", .darkAqua),
      ("Increase Contrast, light", .accessibilityHighContrastAqua),
      ("Increase Contrast, dark", .accessibilityHighContrastDarkAqua),
    ]

    private let sections: [GallerySection] = {
      let only = UserDefaults.standard.string(forKey: "designGallerySection")
      return GallerySection.allCases.filter { only == nil || $0.rawValue == only }
    }()

    var body: some View {
      ScrollView([.horizontal, .vertical]) {
        VStack(alignment: .leading, spacing: Space.xxl.points) {
          SystemSettingsNote()
          let columns = sections.filter { $0 != .motion && $0 != .overlay }
          if !columns.isEmpty {
            HStack(alignment: .top, spacing: 0) {
              ForEach(Self.appearances, id: \.title) { appearance in
                AppearanceHost(appearance: appearance.name) {
                  TokenColumn(title: appearance.title, sections: columns)
                }
              }
            }
          }
          if sections.contains(.overlay) {
            HStack(alignment: .top, spacing: 0) {
              ForEach(Self.appearances, id: \.title) { appearance in
                AppearanceHost(appearance: appearance.name) {
                  OverlayColumn(title: appearance.title)
                }
              }
            }
          }
          if sections.contains(.motion) {
            MotionSection()
          }
        }
        .padding(Space.xl)
      }
    }
  }

  private enum GallerySection: String, CaseIterable {
    case type
    case spacing
    case radius
    case color
    case surface
    case overlay
    case components
    case sidebar
    case panels
    case motion
    case language
  }

  /// Hosts content in its own NSHostingView so system colors, materials and glass resolve
  /// against a forced appearance, the same way they do in a window.
  private struct AppearanceHost<Content: View>: NSViewRepresentable {
    let appearance: NSAppearance.Name
    let content: Content

    init(appearance: NSAppearance.Name, @ViewBuilder content: () -> Content) {
      self.appearance = appearance
      self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<Content> {
      let view = NSHostingView(rootView: content)
      view.appearance = NSAppearance(named: appearance)
      return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
      view.rootView = content
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context
    ) -> CGSize? {
      nsView.fittingSize
    }
  }

  private struct SystemSettingsNote: View {
    var body: some View {
      let workspace = NSWorkspace.shared
      VStack(alignment: .leading, spacing: Space.xs.points) {
        Text("Design Gallery").textStyle(.largeTitle)
        Text(
          "System settings now: Reduce Transparency \(state(workspace.accessibilityDisplayShouldReduceTransparency)), Increase Contrast \(state(workspace.accessibilityDisplayShouldIncreaseContrast)), Reduce Motion \(state(workspace.accessibilityDisplayShouldReduceMotion))."
        )
        .textStyle(.callout)
        Text(
          "Materials and Liquid Glass read Reduce Transparency from the system, so no column can force it. Turn it on in System Settings › Accessibility › Display and reopen this window to check the fallback."
        )
        .textStyle(.callout)
        .foregroundStyle(.secondary)
      }
    }

    private func state(_ on: Bool) -> String { on ? "on" : "off" }
  }

  private struct TokenColumn: View {
    let title: String
    let sections: [GallerySection]

    var body: some View {
      VStack(alignment: .leading, spacing: Space.xxl.points) {
        Text(title).textStyle(.title3).fontWeight(.semibold)
        ForEach(sections, id: \.self) { section in
          switch section {
          case .type: TypeSection()
          case .spacing: SpacingSection()
          case .radius:
            RadiusSection()
            IconSizeSection()
          case .color: ColorSection()
          case .surface: SurfaceSection()
          case .components: ComponentsSection()
          case .sidebar: SidebarSection()
          case .panels: PanelsSection()
          case .motion, .overlay: EmptyView()
          case .language: LanguageSection()
          }
        }
      }
      .padding(Space.xl)
      .frame(width: 340, alignment: .topLeading)
      .background(.token(.windowBackground))
      .tint(.token(.accent))
    }
  }

  private struct SectionTitle: View {
    let text: String

    var body: some View {
      Text(text).textStyle(.headline).foregroundStyle(.secondary)
    }
  }

  private struct TypeSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.m.points) {
        SectionTitle(text: "Type")
        ForEach(TextStyle.allCases, id: \.self) { style in
          VStack(alignment: .leading, spacing: Space.xxs.points) {
            Text(sample(for: style)).textStyle(style).lineLimit(1)
            Text("\(style.rawValue) · \(Int(style.points)) pt")
              .textStyle(.caption)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }

    private func sample(for style: TextStyle) -> String {
      switch style {
      case .numeral: "1,284"
      case .code: "~/Library/Application Support"
      case .overlayLabel: "Transcribing"
      case .overlayGlyph: "Paste ⌘V"
      default: "Hold the shortcut and speak."
      }
    }
  }

  private struct SpacingSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.s.points) {
        SectionTitle(text: "Spacing")
        ForEach(Space.allCases, id: \.self) { space in
          HStack(spacing: Space.m.points) {
            Rectangle()
              .fill(.token(.accent))
              .frame(width: space.points, height: Space.m.points)
              .frame(width: Space.xxxl.points, alignment: .leading)
            Text("\(String(describing: space)) · \(Int(space.points)) pt").textStyle(.callout)
          }
        }
      }
    }
  }

  private struct RadiusSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.s.points) {
        SectionTitle(text: "Corner radius")
        HStack(spacing: Space.l.points) {
          ForEach(Radius.allCases, id: \.self) { radius in
            VStack(spacing: Space.xs.points) {
              radius.shape
                .fill(.token(.contentBackground))
                .overlay(radius.shape.stroke(.token(.separator)))
                .frame(width: 72, height: 48)
              Text("\(String(describing: radius)) · \(Int(radius.points))").textStyle(.caption)
            }
          }
        }
      }
    }
  }

  private struct IconSizeSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.s.points) {
        SectionTitle(text: "Icon size")
        HStack(spacing: Space.l.points) {
          ForEach(IconSize.allCases, id: \.self) { size in
            VStack(spacing: Space.xs.points) {
              AppIcon(bundleID: nil, size: size)
              Text("\(String(describing: size)) · \(Int(size.points))").textStyle(.caption)
            }
          }
        }
      }
    }
  }

  private struct ColorSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.s.points) {
        SectionTitle(text: "Color")
        ForEach(SemanticColor.allCases, id: \.self) { color in
          HStack(spacing: Space.s.points) {
            Circle()
              .fill(color.color)
              .overlay(Circle().stroke(.token(.separator)))
              .frame(width: Space.l.points, height: Space.l.points)
            Text(color.rawValue).textStyle(.callout)
          }
        }
        HStack(spacing: Space.m.points) {
          Button("Continue") {}.appButton(.primary)
          Button("Cancel") {}.appButton()
          Toggle("Sounds", isOn: .constant(true)).switchStyle().fixedSize()
        }
        .tint(.token(.accent))
        Text("Paste ⌘V")
          .textStyle(.overlayLabel)
          .foregroundStyle(.token(.onAccent))
          .padding(.horizontal, OverlayMetrics.labelInset)
          .frame(height: OverlayMetrics.islandHeight)
          .background(.token(.accent), in: Capsule())
        HStack(spacing: Space.m.points) {
          Text("primary").foregroundStyle(.primary)
          Text("secondary").foregroundStyle(.secondary)
          Text("tertiary").foregroundStyle(.tertiary)
        }
        .textStyle(.callout)
      }
    }
  }

  private struct SurfaceSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.s.points) {
        SectionTitle(text: "Surface")
        sample
        sample
          .padding(Space.m)
          .background(
            LinearGradient(
              colors: [.token(.accent), .token(.success), .token(.attention)],
              startPoint: .leading, endPoint: .trailing),
            in: Radius.card.shape)
      }
    }

    private var sample: some View {
      HStack(spacing: Space.m.points) {
        VStack(alignment: .leading, spacing: Space.xxs.points) {
          Text("1,284").textStyle(.numeral)
          Text("words today").textStyle(.callout).foregroundStyle(.secondary)
        }
        .padding(Space.l)
        .surface(.card, in: Radius.card.shape)
        VStack(alignment: .leading, spacing: Space.s.points) {
          Label("Control", systemImage: "slider.horizontal.3")
            .textStyle(.overlayLabel)
            .padding(.horizontal, OverlayMetrics.labelInset)
            .frame(height: OverlayMetrics.islandHeight)
            .surface(.control, in: Capsule())
          Label("Recording", systemImage: "mic.fill")
            .textStyle(.overlayLabel)
            .padding(.horizontal, OverlayMetrics.labelInset)
            .frame(height: OverlayMetrics.islandHeight)
            .surface(.island, in: Capsule())
        }
      }
    }
  }

  private struct SidebarSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.l.points) {
        SectionTitle(text: "Sidebar")
        SectionHeader(title: "Sidebar footer", detail: "Selected, plain, with an accessory")
        SidebarFooter {
          SidebarRow("Settings", systemImage: "gearshape", isSelected: true, action: {})
          SidebarRow("Help", systemImage: "questionmark.circle", isSelected: false, action: {})
          SidebarRow("Settings", systemImage: "gearshape", isSelected: false, action: {}) {
            StatusIcon(.attention)
          }
        }
        SectionHeader(
          title: "Sidebar notice", detail: "Update ready, update available, at the sidebar's width")
        SidebarFooter {
          SidebarNotice(
            "Restart to Update", detail: "Version 1.4.0", systemImage: "arrow.clockwise.circle.fill",
            action: {})
          SidebarNotice(
            "Update Available", detail: "Version 1.10.12", systemImage: "arrow.down.circle.fill", action: {})
        } content: {
          SidebarRow("Settings", systemImage: "gearshape", isSelected: false, action: {})
        }
        // The main window's sidebar column width, so a notice that overflows it truncates here too.
        .frame(width: 200)
      }
    }
  }

  private struct LanguageSection: View {
    private let languages = ["en_US", "en_GB", "pl_PL", "de_DE", "es_ES", "fr_FR", "ja_JP"]
      .map(Locale.init(identifier:))

    var body: some View {
      VStack(alignment: .leading, spacing: Space.l.points) {
        SectionTitle(text: "Language picker")
        SectionHeader(title: "Control", detail: "Chosen, then none chosen")
        LanguagePicker(languages: languages, chosen: languages[2]) { _ in }
        LanguagePicker(languages: languages, chosen: nil) { _ in }
        SectionHeader(title: "Popover content")
        LanguagePopover(languages: languages, chosen: languages[2]) { _ in }
          .frame(width: 300, height: 360)
          .background(.token(.selection), in: Radius.panel.shape)
      }
    }
  }

  private struct ComponentsSection: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Space.l.points) {
        SectionTitle(text: "Components")
        SectionHeader(title: "Buttons", detail: "ButtonVariant × ControlScale")
        ForEach(ControlScale.allCases, id: \.self) { size in
          HStack(spacing: Space.s.points) {
            ForEach(ButtonVariant.allCases, id: \.self) { variant in
              Button(variant.rawValue.capitalized) {}.appButton(variant, size: size)
            }
          }
        }
        SectionHeader(title: "Status")
        VStack(alignment: .leading, spacing: Space.m.points) {
          ForEach(Status.allCases, id: \.self) { status in
            StatusRow(title: status.rawValue.capitalized, detail: detail(for: status), status: status)
          }
        }
        SectionHeader(title: "Tags")
        HStack(spacing: Space.xs.points) {
          Tag("Active", systemImage: "checkmark.circle.fill", tint: .success)
          Tag("Loading", systemImage: "arrow.down.circle")
          Tag("25 languages")
          Tag("483 MB")
        }
        SectionHeader(title: "Copy button", detail: "Press it: the confirmation holds 1.2 s")
        HStack(spacing: Space.l.points) {
          GalleryCopyButton(showsTitle: false)
          GalleryCopyButton(showsTitle: true)
        }
        SectionHeader(title: "Icon buttons", detail: "Quiet actions beside a copy button")
        HStack(spacing: Space.xs.points) {
          GalleryCopyButton(showsTitle: false)
          IconButton("Delete", systemImage: "trash") {}
          IconButton("Close", systemImage: "xmark") {}
        }
        SectionHeader(title: "Key caps")
        HStack(spacing: Space.xs.points) {
          KeyCap("fn")
          KeyCap("⌘V")
          KeyCap("⌥ Space")
          KeyCap("Right ⌘", isPressed: true)
          KeyCap("")
        }
        SectionHeader(title: "Large key caps", detail: "One key per cap; pressed, it sinks onto its side")
        HStack(spacing: Space.s.points) {
          KeyCap("⌥", size: .large)
          KeyCap("Space", size: .large)
          KeyCap("D", size: .large)
          KeyCap("fn", isPressed: true, size: .large)
        }
        SectionHeader(
          title: "Confetti", detail: "Fires on a trigger change; festive colors, nothing under Reduce Motion")
        GalleryConfetti()
        SectionHeader(title: "Countdown bar", detail: "Restarts a 10 s window each time the gallery opens")
        CountdownBar(until: .now.addingTimeInterval(10), total: .seconds(10))
          .frame(width: OverlayMetrics.cardMaxWidth / 2)
      }
    }

    private func detail(for status: Status) -> String {
      switch status {
      case .ok: "Granted"
      case .progress: "Loading"
      case .attention: "Allow OpenVocally in System Settings"
      case .failed: "Couldn't load. Restart to try again."
      }
    }
  }

  private struct PanelsSection: View {
    static let week: [TimePoint] = [420, 1_284, 0, 860, 2_310, 640, 975].enumerated().map { day, words in
      let start = Calendar.current.date(
        byAdding: .day, value: day - 6, to: Calendar.current.startOfDay(for: .now))
      return TimePoint(start: start ?? .now, value: Double(words))
    }

    static let hours: [[Int]] = (0..<7).map { day in
      (0..<24).map { hour in (9...18).contains(hour) && day < 5 ? (hour * 37 + day * 53) % 400 : 0 }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: Space.l.points) {
        SectionTitle(text: "Panels")
        SectionHeader(title: "Cards")
        Columns(minWidth: 140) {
          StatTile(value: "1,284", label: "words today")
          StatTile(value: "42", label: "dictations")
          StatTile(value: "2h 5m", label: "Dictation time", detail: "24s per session") {
            Tag("+12.3%", systemImage: "arrow.up.right", tint: .success)
          }
        }
        ForEach([TimeChart<EmptyView>.Style.area, .bars], id: \.self) { style in
          Card {
            TimeChart(
              "Words by day", points: Self.week, unit: .day, style: style, noun: "words",
              detail: "6,489 words in total", emptyText: "No dictation yet")
          }
        }
        Card {
          WeekHeatmap("When you dictate", values: Self.hours, noun: "words", emptyText: "No dictation yet")
        }
        SectionHeader(title: "Empty state", detail: "Native ContentUnavailableView")
        Card {
          ContentUnavailableView {
            Label("No dictations yet", systemImage: "waveform")
          } description: {
            Text("Hold the shortcut and speak.")
          } actions: {
            Button("Set Shortcut") {}.appButton(.secondary, size: .small)
          }
        }
        SectionHeader(title: "Setting row", detail: "The control centers against both lines")
        SettingRow("Overlay", subtitle: "Displays without a notch show the island at the top.") {
          Picker("Overlay", selection: .constant(0)) {
            Text("Notch").tag(0)
            Text("Island").tag(1)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        SectionHeader(title: "Banners")
        Banner(
          tone: .info, title: "New model available",
          message: "Parakeet v3 is faster on long phrases.")
        Banner(
          tone: .attention, title: "Accessibility is off",
          message: "OpenVocally needs it to paste into other apps."
        ) {
          Button("Open Settings") {}.appButton(.primary, size: .small)
          Button("Later") {}.appButton(.quiet, size: .small)
        }
      }
    }
  }

  private struct MotionSection: View {
    @State private var reduceMotion = false

    var body: some View {
      VStack(alignment: .leading, spacing: Space.m.points) {
        HStack(spacing: Space.l.points) {
          SectionTitle(text: "Motion")
          Toggle("Preview Reduce Motion", isOn: $reduceMotion)
        }
        ForEach(Motion.allCases, id: \.self) { motion in
          MotionRow(motion: motion, reduceMotion: reduceMotion)
            .id("\(motion.rawValue)-\(reduceMotion)")
        }
      }
    }
  }

  private struct GalleryConfetti: View {
    @State private var bursts = 0

    var body: some View {
      Button("Fire") { bursts += 1 }
        .appButton()
        .frame(width: 360, height: 200, alignment: .bottom)
        .overlay { ConfettiBurst(trigger: bursts) }
    }
  }

  /// Confirms without touching the pasteboard.
  private struct GalleryCopyButton: View {
    let showsTitle: Bool
    @State private var copied = false

    var body: some View {
      CopyButton("Copy", showsTitle: showsTitle, copied: $copied) { true }
    }
  }

  private struct MotionRow: View {
    let motion: Motion
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
      HStack(spacing: Space.l.points) {
        VStack(alignment: .leading, spacing: Space.xxs.points) {
          Text(motion.rawValue).textStyle(.headline)
          Text(purpose).textStyle(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 360, alignment: .leading)
        demo.frame(width: 180, alignment: .leading)
        Button("Play") {
          withAnimation(motion.resolved(reduceMotion: reduceMotion)) { expanded.toggle() }
        }
      }
    }

    @ViewBuilder private var demo: some View {
      if reduceMotion {
        ZStack(alignment: .leading) {
          bar(width: 48).opacity(expanded ? 0 : 1)
          bar(width: 160).opacity(expanded ? 1 : 0)
        }
      } else {
        bar(width: expanded ? 160 : 48)
      }
    }

    private func bar(width: CGFloat) -> some View {
      Capsule().fill(.token(.accent)).frame(width: width, height: Space.xxl.points)
    }

    private var purpose: String {
      switch motion {
      case .overlayExpand: "Overlay appears. Glyph shows in the first frame."
      case .overlayGrow: "Pill on screen grows into an alert, with a little bounce."
      case .overlayCollapse: "Overlay shrinks. No overshoot."
      case .overlayHide: "Overlay leaves, faster than it came."
      case .overlayContentSwap: "Overlay content changes between phases."
      case .overlayMeter: "Overlay meter bars follow the microphone. Frozen under Reduce Motion."
      case .windowReveal: "A banner or row appears in a window."
      case .windowUnfold: "A row or section opens in place."
      case .press: "A pressed control shrinks a little. Dims under Reduce Motion."
      case .confirm: "Copy turns into a green checkmark."
      case .confirmEnd: "The checkmark goes back, faster than it came."
      case .keyCap: "A held key's cap fades in and sits slightly smaller."
      case .onboardingIntro: "The welcome's icon, title and tagline arrive in turn."
      case .onboardingStep: "An onboarding step slides in from the trailing side."
      case .onboardingExit: "The step that leaves, faster than the one that arrives."
      }
    }
  }

  /// Every overlay state through the real island views, without a panel. Cancel is absent
  /// because it shows nothing.
  private struct OverlayColumn: View {
    let title: String

    private struct Sample: Identifiable {
      let id: String
      let slots: [(OverlaySource, OverlayActivity)]
      var placement = OverlayPlacement.island(.bottom)
      var bands: [Float] = []
    }

    private static let bands: [Float] = (0..<20).map { band in
      Float(max(0.05, 0.9 - abs(Double(band) - 9.5) / 11))
    }

    private static let phases: [(String, DictationPhase)] = [
      ("starting", .starting(.pushToTalk)),
      ("recording", .recording(.toggle)),
      ("stopping", .stopping),
      ("transcribing", .transcribing),
      ("pasting", .pasting),
      ("complete", .complete),
      ("manual paste", .awaitingManualPaste(until: HostTime.now().advanced(by: .seconds(10)))),
      ("manual paste expired", .failed(.manualPasteExpired)),
      ("nothing to paste", .failed(.nothingToPaste)),
      ("microphone denied", .failed(.microphonePermissionDenied)),
      ("no input device", .failed(.captureError(.noInputDevice))),
      ("start timed out", .failed(.captureError(.startTimedOut))),
      ("stop timed out", .failed(.captureError(.stopTimedOut))),
      ("device lost", .failed(.captureError(.deviceLost))),
      ("capture failed", .failed(.captureError(.captureFailed))),
      ("transcription error", .failed(.transcriptionError)),
      ("no speech", .failed(.noSpeech)),
      ("model not installed", .failed(.modelNotInstalled)),
      ("paste not supported", .failed(.pasteNotSupported)),
      ("paste permission denied", .failed(.pastePermissionDenied)),
      ("paste runtime error", .failed(.pasteRuntimeError)),
    ]

    private static let wakingMicrophone = OverlayActivity(
      glyph: nil, status: "Connecting", body: .compact(.status))

    private static let recording = OverlayActivity(
      glyph: nil, status: "Recording", body: .compact(.bars(.live)))

    private static let samples: [Sample] =
      phases.compactMap { name, phase in
        OverlayActivity(dictation: phase).map { activity in
          Sample(id: name, slots: [(.dictation, activity)], bands: bands)
        }
      } + [
        Sample(id: "connecting bluetooth mic", slots: [(.dictation, wakingMicrophone)], bands: bands),
        Sample(id: "top placement", slots: [(.dictation, recording)], placement: .island(.top), bands: bands),
        Sample(
          id: "agent alert",
          slots: [
            (
              .agent,
              OverlayActivity(
                glyph: .agent, status: "Reply drafted", body: .alert(OverlayAlert("Reply drafted")))
            )
          ]),
        Sample(
          id: "card",
          slots: [
            (
              .agent,
              OverlayActivity(
                glyph: .agent, status: "Review",
                body: .card(OverlayCard(title: "Reply drafted", detail: "Three paragraphs, ready to review")))
            )
          ]),
      ]

    private static let notchSamples: [Sample] = samples.filter { $0.placement == .island(.bottom) }
      .map { sample in
        Sample(
          id: "notch \(sample.id)", slots: sample.slots, placement: .notch(.simulated), bands: sample.bands)
      }

    var body: some View {
      VStack(alignment: .leading, spacing: Space.m.points) {
        Text(title).textStyle(.title3).fontWeight(.semibold)
        SectionTitle(text: "Overlay")
        ForEach(Self.samples) { sample in
          VStack(alignment: .leading, spacing: Space.xs.points) {
            Text(sample.id).textStyle(.caption).foregroundStyle(.secondary)
            OverlayPreview(sample.slots, placement: sample.placement, bands: sample.bands)
              .frame(
                width: 460, alignment: Alignment(horizontal: .center, vertical: .center)
              )
              .padding(.vertical, Space.xs)
              .overlay(alignment: sample.placement == .island(.top) ? .top : .bottom) {
                Rectangle().fill(.token(.separator)).frame(height: 1)
              }
          }
        }
        SectionTitle(text: "Notch")
        ForEach(Self.notchSamples) { sample in
          VStack(alignment: .leading, spacing: Space.xs.points) {
            Text(sample.id).textStyle(.caption).foregroundStyle(.secondary)
            OverlayPreview(sample.slots, placement: sample.placement, bands: sample.bands)
              .frame(width: 460, alignment: .top)
              .background(alignment: .top) {
                OverlayPreview([], placement: sample.placement)
              }
          }
        }
      }
      .padding(Space.xl)
      .frame(width: 500, alignment: .topLeading)
      .background(.token(.windowBackground))
    }
  }
#endif
