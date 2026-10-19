#if DEBUG
  import AppKit
  import Darwin
  import DictationCore
  import Observation
  import QuartzCore
  import Storage
  import os

  extension TranscriptsHarness {
    /// Reproduces a main-thread hang: from Transcripts with 20 pages loaded, switches Home, Transcripts,
    /// Home and so on every 40 ms, ending on Home, while a dictation is saved at each switch. Each row is how late
    /// the 40 ms pause came back, which is how long the main thread was blocked. Then Transcripts
    /// must still open.
    static func rapidSwitches(_ model: AppModel, _ database: AppDatabase) async -> Bool {
      writeState("switching")
      defer { writeState("idle") }
      for index in 0..<13 {
        save(database)
        model.screen = index.isMultiple(of: 2) ? .home : .transcripts
        let start = ContinuousClock.now
        await pause(.milliseconds(40))
        record("rapid switch main stall", ScreenSignposts.milliseconds(ContinuousClock.now - start) - 40)
      }
      guard let opened = await openTranscripts(model) else { return false }
      record("rapid switch then tx open", opened)
      return true
    }

    /// Shrinks the window to its minimum width on Transcripts, then opens Home and Settings and
    /// records how far each grew the window, which must be 0.
    static func minimumWidth(_ model: AppModel, _ window: NSWindow) async -> Bool {
      if model.screen != .home {
        guard await openHome(model) != nil else { return false }
        await pause(settle)
      }
      guard await openTranscripts(model) != nil else { return false }
      await pause(settle)
      let minimum = window.contentMinSize.width
      record("window min width pt", Double(minimum))
      window.setContentSize(NSSize(width: minimum, height: window.contentLayoutRect.height))
      await pause(settle)
      let start = window.contentLayoutRect.width
      guard await openHome(model) != nil else { return false }
      await pause(settle)
      record("window growth tx to home pt", Double(window.contentLayoutRect.width - start))
      model.screen = .settings
      await pause(.milliseconds(500))
      record("window growth tx to settings pt", Double(window.contentLayoutRect.width - start))
      return true
    }

    /// `--scenario`: one part of the full run, so a single question costs seconds on screen.
    /// `open` opens Transcripts and Home 10 times each, `sidebar` toggles the sidebar 10 times on
    /// Home and on Transcripts, and `width` opens and closes the transcript detail 10 times, then
    /// runs the minimum width checks.
    static func focused(_ scenario: String, _ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard database != nil, let window = await mainWindow(model) else { return false }
      record("display fps", Double(window.screen?.maximumFramesPerSecond ?? 0))
      await pause(.milliseconds(500))
      switch scenario {
      case "open":
        for index in 0..<10 {
          guard let opened = await openTranscripts(model) else { return fail("open transcripts") }
          record(index == 0 ? "tx open first" : "tx open from home", opened)
          await pause(settle)
          guard let home = await openHome(model) else { return fail("open home") }
          record("home open from tx@1p", home)
          await pause(settle)
        }
        return true
      case "sidebar":
        guard await toggleSidebar(window, label: "home", traceHome: true) else { return fail("sidebar home") }
        guard await openTranscripts(model) != nil else { return fail("open transcripts") }
        await pause(settle)
        return await toggleSidebar(window, label: "tx @1p", traceHome: false) || fail("sidebar")
      case "select":
        return await selectNarrow(model, window) || fail("select at minimum width")
      case "width":
        guard await openTranscripts(model) != nil else { return fail("open transcripts") }
        await pause(settle)
        await toggleDetail(window, label: "tx @1p")
        guard await minimumWidth(model, window) else { return fail("minimum width") }
        return await minimumWidthWithDetail(model, window) || fail("minimum width with detail")
      default:
        return fail("unknown scenario \(scenario)")
      }
    }

    /// Reproduces the list jumping when the detail opens: with the list scrolled to row 20, selects that row, first at
    /// the window's starting width and then at its minimum width. Records the first visible row
    /// before and after, which must not move, and the window's largest one-frame width step.
    static func selectNarrow(_ model: AppModel, _ window: NSWindow) async -> Bool {
      guard await openTranscripts(model) != nil else { return false }
      await pause(settle)
      for label in ["wide", "narrow"] {
        if label == "narrow" {
          let height = window.contentLayoutRect.height
          window.setContentSize(NSSize(width: window.contentMinSize.width, height: height))
          await pause(settle)
        }
        driver.revealRow = nil
        driver.selectRow = nil
        await pause(settle)
        driver.revealRow = 20
        await pause(.milliseconds(500))
        let before = firstVisibleRow(in: window)
        let widthBefore = window.frame.width
        var widths: [CGFloat] = [widthBefore]
        let start = ContinuousClock.now
        driver.selectRow = 20
        let frames = await FrameClock.run(in: window) { _ in
          widths.append(window.frame.width)
          return ContinuousClock.now - start < .milliseconds(1000)
        }
        recordFrames("select \(label)", frames)
        record("select \(label) first visible row before", Double(before))
        record("select \(label) first visible row after", Double(firstVisibleRow(in: window)))
        record("select \(label) window growth pt", Double(window.frame.width - widthBefore))
        let steps = zip(widths, widths.dropFirst()).map { abs($1 - $0) }
        record("select \(label) largest 1-frame window step pt", Double(steps.max() ?? 0))
        driver.inspectRequests += 1
        await pause(.seconds(1))
      }
      return true
    }

    private static func firstVisibleRow(in window: NSWindow) -> Int {
      guard let table = listScrollView(in: window)?.documentView as? NSTableView else { return -1 }
      return table.rows(in: table.visibleRect).location
    }

    /// The same check with the transcript detail open: shrinks the window to its minimum, then
    /// records how far closing the detail and opening Home grew it, which must be 0.
    static func minimumWidthWithDetail(_ model: AppModel, _ window: NSWindow) async -> Bool {
      guard await openTranscripts(model) != nil else { return false }
      await pause(settle)
      driver.inspectRequests += 1
      await pause(.seconds(1))
      let minimum = window.contentMinSize.width
      record("window min width with detail pt", Double(minimum))
      window.setContentSize(NSSize(width: minimum, height: window.contentLayoutRect.height))
      await pause(settle)
      let start = window.contentLayoutRect.width
      driver.inspectRequests += 1
      await pause(.seconds(1))
      record("window growth detail close pt", Double(window.contentLayoutRect.width - start))
      guard await openHome(model) != nil else { return false }
      await pause(settle)
      record("window growth detail to home pt", Double(window.contentLayoutRect.width - start))
      return true
    }

    /// For `xctrace`: loads 10 pages, writes `ready` to the state file, waits 3 s and scrolls the
    /// list down and back for 10 s.
    static func traceScroll(_ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard database != nil, let window = await mainWindow(model) else { return false }
      guard await openTranscripts(model) != nil else { return fail("open transcripts") }
      for _ in 1..<10 {
        guard
          await expect(
            {
              if case .transcriptsGrew = $0 { true } else { false }
            }, { driver.scrollRequests += 1 }) != nil
        else { return fail("load more") }
        await pause(.milliseconds(100))
      }
      writeState("ready")
      await pause(.seconds(3))
      let end = ContinuousClock.now + .seconds(10)
      while ContinuousClock.now < end {
        guard await scroll(window, label: "trace", for: .seconds(3)) else { return fail("scroll") }
      }
      return true
    }

    /// For `xctrace`: writes `ready` to the state file, waits 3 s and switches between Home and
    /// Transcripts for about 9 s.
    static func traceSwitch(_ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard database != nil, await mainWindow(model) != nil else { return false }
      writeState("ready")
      await pause(.seconds(3))
      let end = ContinuousClock.now + .seconds(9)
      while ContinuousClock.now < end {
        guard let opened = await openTranscripts(model) else { return fail("open transcripts") }
        record("tx open from home", opened)
        await pause(settle)
        guard let home = await openHome(model) else { return fail("open home") }
        record("home open from tx@1p", home)
        await pause(settle)
      }
      return true
    }

    /// For `xctrace`: writes `ready` to the state file, waits 3 s and toggles the sidebar 10 times on
    /// Home.
    static func traceSidebar(_ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard database != nil, let window = await mainWindow(model) else { return false }
      writeState("ready")
      await pause(.seconds(3))
      return await toggleSidebar(window, label: "home", traceHome: true)
    }

    /// For `--screenshots`: Transcripts with nothing selected, then with the first row selected.
    /// Each state line names the window, which the script captures while the state holds. Then
    /// the detail opens and closes 10 times and the minimum width check runs.
    static func screenshots(_ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard database != nil, let window = await mainWindow(model) else { return false }
      guard await openTranscripts(model) != nil else { return fail("open transcripts") }
      await pause(.seconds(1))
      writeState("list \(window.windowNumber)")
      await pause(.seconds(3))
      driver.inspectRequests += 1
      await pause(.seconds(1))
      writeState("detail \(window.windowNumber)")
      await pause(.seconds(3))
      driver.inspectRequests += 1
      await pause(.seconds(1))
      await toggleDetail(window, label: "tx @1p")
      return await minimumWidth(model, window)
    }

    /// For a screen recording: Home, `ready` in the state file, then after 2 s a collapse and an
    /// expand 1.5 s apart.
    static func sidebarDemo(_ model: AppModel, _ database: AppDatabase?) async -> Bool {
      guard database != nil, let window = await mainWindow(model), let split = splitViewController(in: window)
      else { return false }
      writeState("ready")
      await pause(.seconds(2))
      split.toggleSidebar(nil)
      await pause(.milliseconds(1500))
      split.toggleSidebar(nil)
      await pause(.milliseconds(1500))
      return true
    }
  }
#endif
