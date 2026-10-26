#if FEATURE_AGENTS
  import Agents
  import AgentsCore
  import AppKit
  import Observation
  import SwiftUI
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "agents")

  /// The project actions on the Agents screen, and the rename and problem alerts they raise. The window owns one and attaches its alerts.
  @MainActor @Observable final class AgentsActions {
    var renaming: Project.ID?
    var renameText = ""
    var problem: String?

    func add(_ agents: AgentsService) async {
      guard let url = Self.chooseFolder(prompt: "Add") else { return }
      do {
        if case .rejected(let rejection) = try await agents.addProject(at: url) {
          problem = Self.message(rejection)
        }
      } catch {
        fail("Adding a project", error)
      }
    }

    func locate(_ id: Project.ID, _ agents: AgentsService) async {
      guard let url = Self.chooseFolder(prompt: "Locate") else { return }
      do {
        switch try await agents.locate(id, at: url) {
        case .relocated, .unchanged: break
        case .alreadyAProject: problem = "That folder is already a project."
        case .rejected(let rejection): problem = Self.message(rejection)
        }
      } catch {
        fail("Locating a project", error)
      }
    }

    func beginRename(_ row: ProjectRow) {
      renameText = row.project.name
      renaming = row.id
    }

    /// Takes the id and the name, not `renaming`: the alert clears `renaming` as it closes, before
    /// this runs.
    func commitRename(_ id: Project.ID, to name: String, _ agents: AgentsService) async {
      do {
        try await agents.rename(id, to: name)
      } catch {
        fail("Renaming a project", error)
      }
    }

    func remove(_ id: Project.ID, _ agents: AgentsService) async {
      do {
        try await agents.remove(id)
      } catch {
        fail("Removing a project", error)
      }
    }

    func showInFinder(_ row: ProjectRow) {
      NSWorkspace.shared.activateFileViewerSelecting([row.project.path.url])
    }

    private func fail(_ action: String, _ error: any Error) {
      logger.error("\(action, privacy: .public) failed: \(String(describing: error), privacy: .private)")
      problem = "Something went wrong. Try again."
    }

    private static func message(_ rejection: ProjectPathRejection) -> String {
      switch rejection {
      case .notAFolder: "Choose a folder."
      case .openVocallyWorktree: "OpenVocally’s own worktrees can’t be projects."
      }
    }

    private static func chooseFolder(prompt: String) -> URL? {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = prompt
      return panel.runModal() == .OK ? panel.url : nil
    }
  }

  extension View {
    /// The rename and problem alerts for `actions`.
    func agentsAlerts(_ actions: AgentsActions, agents: AgentsService?) -> some View {
      modifier(AgentsAlerts(actions: actions, agents: agents))
    }
  }

  private struct AgentsAlerts: ViewModifier {
    @Bindable var actions: AgentsActions
    let agents: AgentsService?

    func body(content: Content) -> some View {
      content
        .alert("Rename Project", isPresented: renaming) {
          TextField("Name", text: $actions.renameText)
          Button("Rename") {
            guard let agents, let id = actions.renaming else { return }
            let name = actions.renameText
            Task { await actions.commitRename(id, to: name, agents) }
          }
          .keyboardShortcut(.defaultAction)
          Button("Cancel", role: .cancel) { actions.renaming = nil }
        } message: {
          Text("Leave it empty to use the folder’s name.")
        }
        .alert(actions.problem ?? "", isPresented: problem) {
          Button("OK", role: .cancel) { actions.problem = nil }
        }
    }

    private var renaming: Binding<Bool> {
      Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })
    }

    private var problem: Binding<Bool> {
      Binding(get: { actions.problem != nil }, set: { if !$0 { actions.problem = nil } })
    }
  }
#endif
