#if FEATURE_AGENTS
  import Agents
  import AppKit
  import DesignSystem
  import SwiftUI

  /// One section per coding agent CLI. OpenVocally never installs or signs in a CLI: those problems
  /// show the command to run in Terminal, with a button that copies it. An update it can attribute
  /// shows its command too, and an Update button that runs exactly that command.
  struct AgentsSections: View {
    let agents: AgentHealthService

    var body: some View {
      ForEach(AgentKind.allCases) { kind in
        Section(kind.spec.displayName) { ProviderRows(agents: agents, kind: kind) }
          .id(Self.sectionID(kind))
      }
    }

    static func sectionID(_ kind: AgentKind) -> String { "agents-\(kind.rawValue)" }
  }

  private struct ProviderRows: View {
    let agents: AgentHealthService
    let kind: AgentKind

    private var state: AgentHealthService.State { agents[kind] }
    private var spec: AgentSpec { kind.spec }
    private var health: ProviderHealth { state.health }

    var body: some View {
      SettingRow("Enabled", subtitle: enabledSubtitle) {
        Toggle("Enabled", isOn: enabled).labelsHidden().switchStyle()
          .accessibilityLabel(enabledLabel)
      }
      if state.configuration.enabled {
        statusRow
        if let run = state.updateRunWithoutOffer, let message = run.message {
          UpdateMessage(message: message, isProblem: run.isProblem, run: run)
        }
        signInRow
        if case .notFound = health {
          CommandRow(title: "Install", command: spec.installCommand)
          LabeledContent("Install guide") {
            Link("Open Install Guide", destination: spec.installGuide)
          }
        }
        PathRow(agents: agents, kind: kind)
        versionRows
        LaunchArgumentsRow(agents: agents, kind: kind)
      }
    }

    private var enabled: Binding<Bool> {
      Binding(
        get: { state.configuration.enabled },
        set: { agents.setEnabled($0, for: kind) })
    }

    private var enabledSubtitle: String {
      state.configuration.enabled
        ? "Checks \(spec.executableName) on this Mac and when you come back to OpenVocally."
        : health.detail(for: kind)
    }

    /// Reads the status too while off, since the status row is hidden then.
    private var enabledLabel: String {
      state.configuration.enabled
        ? "\(spec.displayName) enabled" : "\(spec.displayName) enabled, \(HealthStatus.disabled.title)"
    }

    private var statusRow: some View {
      LabeledContent {
        EmptyView()
      } label: {
        StatusRow(title: health.status.title, detail: health.detail(for: kind), status: status)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(spec.displayName) status, \(health.status.title), \(health.detail(for: kind))")
      }
    }

    private var status: Status {
      switch health.status {
      case .available: .ok
      case .checking: .progress
      case .disabled, .notFound, .needsAttention, .unsupportedVersion, .notAuthenticated,
        .couldntConfirmSignIn:
        .attention
      }
    }

    @ViewBuilder private var signInRow: some View {
      switch health.signIn {
      case .signedIn(let method?):
        ValueRow(title: "Sign-in", value: "Signed in with \(method)")
      case .signedIn(nil):
        ValueRow(title: "Sign-in", value: "Signed in")
      case .signedOut:
        CommandRow(title: "Sign in", command: spec.loginCommand)
      case .unconfirmed, nil:
        EmptyView()
      }
    }

    @ViewBuilder private var versionRows: some View {
      if let installation = health.installation {
        ValueRow(title: "Version", value: installation.version.description)
        if case .bundled(let app) = installation.ownership {
          ValueRow(title: "Updates", value: "Updates with \(app)")
        } else if let offer = state.updateOffer {
          UpdateRow(kind: kind, offer: offer) { agents.installUpdate(for: kind) }
        } else if case .available(let latest) = state.update {
          ValueRow(title: "Update available", value: latest.description)
        }
      }
    }
  }

  /// The version to update to, the button that runs the CLI's own updater, and one line on how
  /// it went.
  private struct UpdateRow: View {
    let kind: AgentKind
    let offer: UpdateOffer
    let start: () -> Void

    var body: some View {
      // Once nothing is left to update, only the outcome line stays.
      if offer.isOutdated {
        LabeledContent {
          HStack(spacing: Space.xs.points) {
            if let latest = offer.latest {
              Text(latest.description).monospacedDigit().accessibilityHidden(true)
            }
            if offer.run.isActive {
              ProgressView().controlSize(.small).accessibilityLabel(offer.run.message ?? "")
            } else {
              Button("Update", action: start)
                .appButton(size: .small)
                .disabled(!offer.canStart)
                .accessibilityLabel("Update \(kind.spec.displayName)")
            }
          }
        } label: {
          if let latest = offer.latest {
            Text("Update available").accessibilityLabel("Update available, \(latest.description)")
          } else {
            Text("Update")
          }
        }
      }
      if let message = offer.message {
        UpdateMessage(message: message, isProblem: offer.isProblem, run: offer.run)
      }
    }
  }

  /// One line on how an update went, announced when a run ends.
  private struct UpdateMessage: View {
    let message: String
    let isProblem: Bool
    let run: UpdateRun

    var body: some View {
      Text(message)
        .textStyle(.callout)
        .foregroundStyle(isProblem ? SemanticColor.attention.color : .secondary)
        .textSelection(.enabled)
        .onChange(of: run) { _, run in
          if !run.isActive, let message = run.message {
            AccessibilityNotification.Announcement(message).post()
          }
        }
    }
  }

  /// A title and a value that VoiceOver reads as one element. Combining a LabeledContent's
  /// children keeps the title and drops the value, and the element SwiftUI makes for it has no
  /// role, so VoiceOver reads its label and not its value.
  private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
      LabeledContent(title) { Text(value).monospacedDigit().textSelection(.enabled) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
  }

  /// A command to paste into Terminal.
  private struct CommandRow: View {
    let title: String
    let command: String
    @State private var copied = false

    var body: some View {
      LabeledContent(title) {
        HStack(spacing: Space.xs.points) {
          Text(command)
            .textStyle(.code)
            .textSelection(.enabled)
            .accessibilityLabel(title)
            .accessibilityValue(command)
          CopyButton("Copy \(command)", copied: $copied) {
            Clipboard.write(command, announcement: "Command copied")
            return true
          }
        }
      }
    }
  }

  /// What put the CLI there, not its path; the path is in the help tag, VoiceOver and the menu.
  /// Choose… stays in view only while no copy runs, when it is the fix.
  private struct PathRow: View {
    let agents: AgentHealthService
    let kind: AgentKind

    var body: some View {
      let state = agents[kind]
      let path = shownPath(state)
      let skipped = state.health.skipped
      let notes = skipped.map(\.note).joined(separator: "\n")
      SettingRow("Location") {
        if let summary = SkippedCopy.summary(skipped) {
          Text(summary).help(notes).accessibilityLabel(summary).accessibilityValue(notes)
        }
      } control: {
        HStack(spacing: Space.xs.points) {
          Text(title(state))
            .foregroundStyle(.secondary)
            .help(path ?? "")
            .accessibilityLabel("\(kind.spec.displayName) location")
            .accessibilityValue([title(state), path].compactMap { $0 }.joined(separator: ", "))
          if state.health.installation == nil {
            Button("Choose…") { Self.choose(agents: agents, kind: kind) }
              .appButton(size: .small)
          }
          Menu {
            if state.health.installation != nil {
              Button("Choose…") { Self.choose(agents: agents, kind: kind) }
            }
            if state.configuration.chosenPath != nil {
              Button("Use Detected") { agents.setChosenPath(nil, for: kind) }
            }
            if let path {
              Divider()
              Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
              }
              Button("Copy Path") { Clipboard.write(path, announcement: "Path copied") }
            }
          } label: {
            Label("\(kind.spec.displayName) location options", systemImage: "ellipsis.circle")
              .labelStyle(.iconOnly)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
      }
    }

    private func title(_ state: AgentHealthService.State) -> String {
      if let installation = state.health.installation { return installation.ownership.title(kind.spec) }
      return state.configuration.chosenPath == nil ? "Not found" : "Chosen file"
    }

    private func shownPath(_ state: AgentHealthService.State) -> String? {
      (state.health.installation?.path ?? state.configuration.chosenPath)?.path(percentEncoded: false)
    }

    /// Files only. Packages open as folders, so the codex inside ChatGPT.app can be picked.
    @MainActor static func choose(agents: AgentHealthService, kind: AgentKind) {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.treatsFilePackagesAsDirectories = true
      panel.message = "Choose the \(kind.spec.executableName) executable."
      panel.prompt = "Choose"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      agents.setChosenPath(url, for: kind)
    }
  }

  /// Saved as typed; split only when a session launches.
  private struct LaunchArgumentsRow: View {
    let agents: AgentHealthService
    let kind: AgentKind
    @State private var text: String

    init(agents: AgentHealthService, kind: AgentKind) {
      self.agents = agents
      self.kind = kind
      _text = State(initialValue: agents[kind].configuration.launchArguments.text)
    }

    var body: some View {
      let spec = kind.spec
      SettingRow("Launch arguments", subtitle: spec.launchArgumentsSubtitle) {
        TextField("Launch arguments", text: $text, prompt: spec.launchArgumentsPlaceholder.map { Text($0) })
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .textStyle(.code)
          .accessibilityLabel("\(spec.displayName) launch arguments")
      }
      .onChange(of: text) { _, text in agents.setLaunchArguments(text, for: kind) }
      if let problem = LaunchArguments(text).problem {
        Text(problem.message)
          .textStyle(.callout)
          .foregroundStyle(SemanticColor.attention.color)
      }
    }
  }
#endif
