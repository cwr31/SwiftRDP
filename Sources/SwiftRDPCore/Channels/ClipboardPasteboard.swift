import AppKit
import Foundation

struct ClipboardLocalSnapshot {
    let changeCount: Int
    let fileURLs: [URL]
    let text: String?
    let html: String?
    let imageTIFF: Data?

    static let empty = ClipboardLocalSnapshot(
        changeCount: -1,
        fileURLs: [],
        text: nil,
        html: nil,
        imageTIFF: nil
    )
}

enum ClipboardRemoteContent {
    case text(String)
    case html(String)
    case image(NSImage)
    case files(ClipboardRemoteFilePromise)
}

/// General copy/paste consumers request file URLs; AppKit file promises are only
/// reliably consumed from drag pasteboards.
private final class ClipboardPasteboardFileProvider: NSObject, NSPasteboardItemDataProvider {
    private let promise: ClipboardRemoteFilePromise
    private let name: String

    init(promise: ClipboardRemoteFilePromise, name: String) {
        self.promise = promise
        self.name = name
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL,
              let url = promise.resolveTopLevel(named: name) else {
            RDPLog.channels.info("Clipboard: failed to materialize promised file \(name)")
            return
        }
        item.setString(url.absoluteString, forType: .fileURL)
    }
}

enum ClipboardPasteboardBridge {
    static func capture(_ pasteboard: NSPasteboard = .general) -> ClipboardLocalSnapshot {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            return ClipboardLocalSnapshot(
                changeCount: pasteboard.changeCount,
                fileURLs: fileURLs,
                text: nil,
                html: nil,
                imageTIFF: nil
            )
        }

        let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        return ClipboardLocalSnapshot(
            changeCount: pasteboard.changeCount,
            fileURLs: [],
            text: pasteboard.string(forType: .string),
            html: pasteboard.string(forType: .html)
                ?? pasteboard.string(forType: NSPasteboard.PasteboardType("public.html")),
            imageTIFF: image?.tiffRepresentation
        )
    }

    static func publish(_ content: ClipboardRemoteContent, to pasteboard: NSPasteboard = .general) -> Int {
        switch content {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .html(let html):
            pasteboard.clearContents()
            let plain = html.data(using: .utf8)
                .flatMap { NSAttributedString(html: $0, documentAttributes: nil) }?.string ?? html
            pasteboard.setString(plain, forType: .string)
            pasteboard.setString(html, forType: .html)
        case .image(let image):
            pasteboard.clearContents()
            if let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        case .files(let promise):
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            let items = promise.topLevelNames.map { name in
                let item = NSPasteboardItem()
                let provider = ClipboardPasteboardFileProvider(promise: promise, name: name)
                item.setDataProvider(provider, forTypes: [.fileURL])
                return item
            }
            pasteboard.writeObjects(items)
        }
        return pasteboard.changeCount
    }
}
