import SwiftUI

/// Views in equal columns, as many as fit at `minWidth` each, halving the count until they fit:
/// four tiles become two rows of two, then one column. Every view in a row takes the row's height.
///
/// It measures each view once per pass, where `ViewThatFits` measures every candidate layout, so
/// a dashboard keeps up with a live window resize such as the sidebar collapsing.
public struct Columns: Layout {
  let minWidth: CGFloat
  let spacing: CGFloat

  public init(minWidth: CGFloat, spacing: Space = .m) {
    self.minWidth = minWidth
    self.spacing = spacing.points
  }

  public struct Cache {
    var width: CGFloat?
    var rows: [Row] = []
  }

  struct Row {
    var range: Range<Int>
    var height: CGFloat
  }

  public func makeCache(subviews: Subviews) -> Cache { Cache() }

  public func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let width = proposal.width ?? CGFloat(subviews.count) * minWidth + gaps(subviews.count)
    let rows = rows(width: width, subviews: subviews, cache: &cache)
    let height = rows.reduce(0) { $0 + $1.height } + gaps(rows.count)
    return CGSize(width: width, height: height)
  }

  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    let count = columnCount(width: bounds.width, items: subviews.count)
    let columnWidth = self.columnWidth(bounds.width, count)
    var y = bounds.minY
    for row in rows(width: bounds.width, subviews: subviews, cache: &cache) {
      for (column, index) in row.range.enumerated() {
        let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
        subviews[index].place(
          at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: columnWidth, height: row.height))
      }
      y += row.height + spacing
    }
  }

  private func rows(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [Row] {
    if cache.width == width { return cache.rows }
    let count = columnCount(width: width, items: subviews.count)
    let proposal = ProposedViewSize(width: columnWidth(width, count), height: nil)
    let rows = stride(from: 0, to: subviews.count, by: count).map { start in
      let range = start..<min(start + count, subviews.count)
      return Row(range: range, height: range.map { subviews[$0].sizeThatFits(proposal).height }.max() ?? 0)
    }
    cache = Cache(width: width, rows: rows)
    return rows
  }

  private func columnCount(width: CGFloat, items: Int) -> Int {
    var count = max(items, 1)
    while count > 1 && CGFloat(count) * minWidth + gaps(count) > width { count = (count + 1) / 2 }
    return count
  }

  private func columnWidth(_ width: CGFloat, _ count: Int) -> CGFloat {
    max(0, (width - gaps(count)) / CGFloat(count))
  }

  private func gaps(_ count: Int) -> CGFloat { CGFloat(max(count - 1, 0)) * spacing }
}
