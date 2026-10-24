#if DEBUG
  import AppKit
  import Darwin
  import DictationCore
  import Observation
  import QuartzCore
  import Storage
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts-harness")

  extension TranscriptsHarness {
    /// Moves the list from its top down 24 points a frame through its loaded rows for at most
    /// `duration`, then back to the top.
    static func scroll(_ window: NSWindow, label: String, for duration: Duration) async -> Bool {
      guard let scrollView = listScrollView(in: window) else {
        logger.error("No list scroll view found")
        return false
      }
      driver.holdPages = true
      defer { driver.holdPages = false }
      let clip = scrollView.contentView
      let top = NSPoint(x: clip.bounds.origin.x, y: -scrollView.contentInsets.top)
      clip.scroll(to: top)
      scrollView.reflectScrolledClipView(clip)
      await pause(settle)
      let end = ContinuousClock.now + duration
      let frames = await FrameClock.run(in: window) { _ in
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        guard ContinuousClock.now < end, clip.bounds.origin.y < maxY else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(maxY, clip.bounds.origin.y + 24)))
        scrollView.reflectScrolledClipView(clip)
        return true
      }
      clip.scroll(to: top)
      scrollView.reflectScrolledClipView(clip)
      recordFrames("scroll \(label)", frames)
      await pause(settle)
      return frames.count > 10
    }

    /// Ten toggles, recording frames for 600 ms after each. On Home it also follows the content,
    /// stats and paired cards' frames on every display frame.
    static func toggleSidebar(_ window: NSWindow, label: String, traceHome: Bool) async -> Bool {
      guard let split = splitViewController(in: window) else {
        logger.error("No split view controller found")
        return false
      }
      for index in 0..<10 {
        let direction = split.splitViewItems.first?.isCollapsed == true ? "expand" : "collapse"
        var samples: [[CGFloat]] = []
        let start = ContinuousClock.now
        split.toggleSidebar(nil)
        let frames = await FrameClock.run(in: window) { _ in
          if traceHome {
            samples.append([
              driver.contentFrame.minX, driver.contentFrame.width, driver.statsFrame.width,
              driver.statsFrame.height,
              driver.pairFrame.height,
              split.splitViewItems.first?.viewController.view.frame.width ?? -1,
              split.splitViewItems.last?.viewController.view.frame.width ?? -1,
            ])
          }
          return ContinuousClock.now - start < .milliseconds(600)
        }
        recordFrames("sidebar \(label) \(direction)", frames)
        if traceHome { recordLayout("home \(direction)", samples, frames: frames, trace: index < 2) }
      }
      return true
    }

    /// Ten opens and closes of the transcript detail, recording frames and the list's width for
    /// 600 ms after each.
    static func toggleDetail(_ window: NSWindow, label: String) async {
      for index in 0..<10 {
        let direction = index.isMultiple(of: 2) ? "open" : "close"
        var samples: [[CGFloat]] = []
        let start = ContinuousClock.now
        let list = listScrollView(in: window)
        driver.inspectRequests += 1
        let frames = await FrameClock.run(in: window) { _ in
          let listFrame = list.map(visibleFrame) ?? .zero
          samples.append([
            listFrame.minX, listFrame.width, driver.contentFrame.width, window.frame.width, 0,
          ])
          return ContinuousClock.now - start < .milliseconds(600)
        }
        recordFrames("detail \(label) \(direction)", frames)
        recordLayout("detail \(direction)", samples, frames: frames, trace: index < 2)
      }
    }

    /// Per toggle: the content's largest one-frame width change against its whole change, and how
    /// many frames changed the stats' and paired cards' heights, which change only when their
    /// column count does.
    private static func recordLayout(_ label: String, _ samples: [[CGFloat]], frames: [Double], trace: Bool) {
      guard let first = samples.first, let last = samples.last else { return }
      var largestStep: CGFloat = 0
      var statsJumps = 0
      var pairJumps = 0
      var moving = 0
      for (previous, current) in zip(samples, samples.dropFirst()) {
        let step = abs(current[1] - previous[1])
        largestStep = max(largestStep, step)
        if step > 0.5 { moving += 1 }
        if abs(current[3] - previous[3]) > 0.5 { statsJumps += 1 }
        if abs(current[4] - previous[4]) > 0.5 { pairJumps += 1 }
      }
      record("layout \(label) width change pt", Double(abs(last[1] - first[1])))
      record("layout \(label) largest 1-frame width step pt", Double(largestStep))
      record("layout \(label) frames with width moving", Double(moving))
      record("layout \(label) stats height changes", Double(statsJumps))
      record("layout \(label) pair height changes", Double(pairJumps))
      guard trace else { return }
      var elapsed = 0.0
      for (index, sample) in samples.enumerated() {
        if index > 0, index - 1 < frames.count { elapsed += frames[index - 1] }
        results.append(
          "trace \(label)\t"
            + ([elapsed] + sample.map(Double.init)).map { String(format: "%.1f", $0) }.joined(separator: "\t")
        )
      }
    }

    static func mainWindow(_ model: AppModel) async -> NSWindow? {
      for _ in 0..<100 {
        if model.windowOpener != nil,
          let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.width >= 600 })
        {
          // The same screen and size every run: frame rates differ between displays, and the
          // window's size sets how many rows are on screen and how many columns Home lays out.
          if let screen = NSScreen.screens.first {
            let size = NSSize(width: 900, height: 670)
            let visible = screen.visibleFrame
            window.setFrame(
              NSRect(
                origin: NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2),
                size: size),
              display: true)
          }
          // An occluded window draws no frames, so the frame and layout rows need it in front.
          NSApplication.shared.activate()
          window.orderFrontRegardless()
          return window
        }
        await pause(.milliseconds(100))
      }
      logger.error("The main window did not appear")
      return nil
    }

    static func splitViewController(in window: NSWindow) -> NSSplitViewController? {
      var controllers = window.contentViewController.map { [$0] } ?? []
      while let controller = controllers.popLast() {
        if let split = controller as? NSSplitViewController { return split }
        controllers.append(contentsOf: controller.children)
      }
      var views = window.contentView.map { [$0] } ?? []
      while let view = views.popLast() {
        if let split = (view as? NSSplitView)?.delegate as? NSSplitViewController { return split }
        views.append(contentsOf: view.subviews)
      }
      return nil
    }

    /// The part of a scroll view its content insets leave visible, in window coordinates. The
    /// inspector can inset the list instead of narrowing it.
    private static func visibleFrame(_ scrollView: NSScrollView) -> CGRect {
      let insets = scrollView.contentInsets
      let frame = scrollView.convert(scrollView.bounds, to: nil)
      return CGRect(
        x: frame.minX + insets.left, y: frame.minY, width: frame.width - insets.left - insets.right,
        height: frame.height)
    }

    /// The transcripts list: the table with the tallest content. The sidebar's table is short, and
    /// the transcript detail scrolls without a table.
    static func listScrollView(in window: NSWindow) -> NSScrollView? {
      var best: NSScrollView?
      var tallest = 0.0
      var stack = window.contentView.map { [$0] } ?? []
      while let view = stack.popLast() {
        if let scrollView = view as? NSScrollView, let document = scrollView.documentView as? NSTableView,
          document.frame.height > tallest
        {
          best = scrollView
          tallest = document.frame.height
        }
        stack.append(contentsOf: view.subviews)
      }
      return best
    }
  }
#endif
