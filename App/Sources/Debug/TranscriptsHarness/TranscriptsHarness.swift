#if DEBUG
  import AppKit
  import Darwin
  import DictationCore
  import Observation
  import QuartzCore
  import Storage
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts-harness")

  /// `make transcripts-latency`. Launch with `-transcriptsHarness YES -seedTranscripts N
  /// -harnessOutput PATH` to run the Home and Transcripts screens on a seeded copy of the database:
  /// open them, switch between them, load more pages, scroll the list and toggle the sidebar while a
  /// display link records frame times and Home's layout, save synthetic dictations while a screen
  /// is open, record memory, write the results to PATH and quit. The hotkeys, microphone and models
  /// never start, and no keyboard or mouse event is posted: scrolling moves the list's clip view,
  /// and the sidebar toggles through its split view controller, as the toolbar button does.
  @MainActor enum TranscriptsHarness {
    @Observable final class Driver {
      /// Each increment scrolls the list to its last row, which loads the next page the way a
      /// user's scroll does.
      var scrollRequests = 0
      /// Each increment selects the first row when nothing is selected, which opens the
      /// transcript detail, and clears the selection otherwise, which closes it.
      var inspectRequests = 0
      /// Scrolls the row at this index to the middle of the list.
      var revealRow: Int?
      /// Selects the row at this index, which opens the transcript detail.
      var selectRow: Int?
      /// Keeps the page count fixed while the harness scrolls.
      @ObservationIgnored var holdPages = false
      /// The detail column's and Home's frames in window coordinates, read on every display frame during a sidebar toggle.
      @ObservationIgnored var contentFrame = CGRect.zero
      @ObservationIgnored var statsFrame = CGRect.zero
      @ObservationIgnored var pairFrame = CGRect.zero
    }

    static let driver = Driver()

    static var isRequested: Bool {
      UserDefaults.standard.bool(forKey: "transcriptsHarness")
    }

    /// `-seedTranscripts N` opens `seed-N.sqlite` next to the real database instead of it.
    nonisolated static var seedRows: Int? {
      let rows = UserDefaults.standard.integer(forKey: "seedTranscripts")
      return rows > 0 ? rows : nil
    }

    struct Waiter {
      let id: Int
      let matches: (ScreenSignposts.Mark) -> Bool
      let resume: CheckedContinuation<ScreenSignposts.Mark?, Never>
    }

    private static let pageLevels = [1, 5, 10, 20]
    static let settle = Duration.milliseconds(150)
    static var waiter: Waiter?
    static var waiterID = 0
    private static var homeSessions = 0
    static var results: [String] = []
    static var savedCount = 0
    static var saves: [Task<Void, Never>] = []
    /// The target app the synthetic dictations are saved under, which no seeded row uses.
    static let appName = "Harness"

    static func run(_ model: AppModel, database: AppDatabase?) async {
      ScreenSignposts.observer = { mark in
        if case .homeUpdated(let sessions) = mark { homeSessions = sessions }
        if case .firstValue(let screen, let ms) = mark { record("\(screen) first value", ms) }
        guard let current = waiter, current.matches(mark) else { return }
        waiter = nil
        current.resume.resume(returning: mark)
      }
      let started = ContinuousClock.now
      let ok: Bool
      if await !seedIntact(database) {
        ok = false
      } else if UserDefaults.standard.bool(forKey: "harnessTraceScroll") {
        ok = await traceScroll(model, database)
      } else if UserDefaults.standard.bool(forKey: "harnessTraceSwitch") {
        ok = await traceSwitch(model, database)
      } else if UserDefaults.standard.bool(forKey: "harnessTraceSidebar") {
        ok = await traceSidebar(model, database)
      } else if UserDefaults.standard.bool(forKey: "harnessScreenshots") {
        ok = await screenshots(model, database)
      } else if UserDefaults.standard.bool(forKey: "harnessSidebarDemo") {
        ok = await sidebarDemo(model, database)
      } else if let scenario = UserDefaults.standard.string(forKey: "harnessScenario") {
        ok = await focused(scenario, model, database)
      } else {
        ok = await drive(model, database)
      }
      let clean = await removeSaves(database)
      if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.width >= 600 }) {
        record("window visible at end", window.occlusionState.contains(.visible) ? 1 : 0)
      }
      record("harness wall s", ScreenSignposts.milliseconds(ContinuousClock.now - started) / 1000)
      results.append("done\t\(ok && clean ? 1 : 0)")
      writeResults()
      logger.notice("Harness finished, ok: \(ok, privacy: .public)")
      // From a main-actor job, terminate's nested event loop never runs the main-actor shutdown
      // task that answers terminateLater, so the app would never quit. A run loop timer is not one.
      NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func drive(_ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard let database, let window = await mainWindow(model) else { return false }
      record("display fps", Double(window.screen?.maximumFramesPerSecond ?? 0))
      await pause(.milliseconds(500))
      recordMemory("launch (home)")

      for index in 0..<3 {
        guard let opened = await openTranscripts(model) else { return fail("open transcripts") }
        record(index == 0 ? "tx open first" : "tx open from home", opened)
        await pause(settle)
        guard let home = await openHome(model) else { return fail("open home") }
        record("home open from tx@1p", home)
        await pause(settle)
      }
      recordMemory("home")

      for _ in 0..<5 {
        let target = homeSessions + 1
        let start = ContinuousClock.now
        guard
          await expect(
            {
              if case .homeUpdated(let sessions) = $0 { sessions >= target } else { false }
            }, { save(database) }) != nil
        else { return fail("home update") }
        record("home save to update", ScreenSignposts.milliseconds(ContinuousClock.now - start))
        await pause(settle)
      }
      recordMemory("home after saves")
      guard await toggleSidebar(window, label: "home", traceHome: true) else { return fail("sidebar home") }

      guard let opened = await openTranscripts(model) else { return fail("open transcripts") }
      record("tx open from home", opened)
      await pause(settle)
      var pages = 1
      for level in pageLevels {
        while pages < level {
          guard
            let grew = await expect(
              {
                if case .transcriptsGrew = $0 { true } else { false }
              }, { driver.scrollRequests += 1 }),
            case .transcriptsGrew(let page, let ms, _) = grew
          else { return fail("load more") }
          record(String(format: "tx more to %02dp", page + 1), ms)
          pages = page + 1
          await pause(.milliseconds(100))
        }
        recordMemory("tx @\(level)p")
        for _ in 0..<5 {
          guard
            let shown = await expect(
              {
                if case .transcriptsNewRow = $0 { true } else { false }
              }, { save(database) }),
            case .transcriptsNewRow(let ms, _) = shown
          else { return fail("save at \(level) pages") }
          record("tx save to row @\(level)p", ms)
          await pause(settle)
        }
        guard await scroll(window, label: "tx @\(level)p", for: .seconds(3)) else { return fail("scroll") }
        if level == 1 || level == 10 {
          guard await toggleSidebar(window, label: "tx @\(level)p", traceHome: false) else {
            return fail("sidebar")
          }
        }
        if level == 10 { await toggleDetail(window, label: "tx @\(level)p") }
        if level <= 10 {
          guard let home = await timedSwitch({ await openHome(model) }) else { return fail("switch to home") }
          record("switch tx@\(level)p to home", home)
          await pause(settle)
          guard let back = await timedSwitch({ await openTranscripts(model) }) else {
            return fail("switch to transcripts")
          }
          record("switch home to tx (after @\(level)p)", back)
          pages = 1
          await pause(settle)
        }
      }
      guard await rapidSwitches(model, database) else { return fail("rapid switches") }
      guard await minimumWidth(model, window) else { return fail("minimum width") }
      recordMemory("end")
      return true
    }

    static func openTranscripts(_ model: AppModel) async -> Double? {
      await open(model, .transcripts) { if case .transcriptsOpened = $0 { true } else { false } }
    }

    static func openHome(_ model: AppModel) async -> Double? {
      await open(model, .home) { if case .homeOpened = $0 { true } else { false } }
    }

    /// From the screen change to the first display frame after the screen reports its content
    /// shown. The report alone can run before the layout that draws the content, which made the
    /// first Transcripts open read 20 to 35 ms in some launches when it took 135 ms.
    private static func open(
      _ model: AppModel, _ screen: Screen, shown: @escaping (ScreenSignposts.Mark) -> Bool
    ) async -> Double? {
      let start = ContinuousClock.now
      guard await expect(shown, { model.screen = screen }) != nil else { return nil }
      if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.width >= 600 }) {
        _ = await FrameClock.run(in: window) { _ in false }
      }
      return ScreenSignposts.milliseconds(ContinuousClock.now - start)
    }

    /// Tells the script a switch is under way, so it can sample a main thread that stalls.
    private static func timedSwitch(_ body: () async -> Double?) async -> Double? {
      writeState("switching")
      defer { writeState("idle") }
      return await body()
    }

    static var outputURL: URL? {
      UserDefaults.standard.string(forKey: "harnessOutput").map { URL(filePath: $0) }
    }

  }
#endif
