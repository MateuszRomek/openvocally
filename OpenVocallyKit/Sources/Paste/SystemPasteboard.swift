import AppKit

/// NSPasteboard.general, read and written from the Paster actor.
struct SystemPasteboard: Pasteboard {
  var changeCount: Int { NSPasteboard.general.changeCount }

  func readItems() -> [PasteboardItemSnapshot] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
      PasteboardItemSnapshot(
        representations: item.types.compactMap { type in
          item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
        })
    }
  }

  func replace(with items: [PasteboardItemSnapshot], currentHostOnly: Bool) -> Int {
    let board = NSPasteboard.general
    if currentHostOnly {
      board.prepareForNewContents(with: .currentHostOnly)
    } else {
      board.clearContents()
    }
    let objects = items.map { snapshot in
      let item = NSPasteboardItem()
      for representation in snapshot.representations {
        item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
      }
      return item
    }
    if !objects.isEmpty { board.writeObjects(objects) }
    return board.changeCount
  }
}
