import AppKit
import SwiftRDPCore
import SwiftUI

/// Live tail of `RDPLog` file mirror (`~/Library/Logs/SwiftRDP/server.log`).
struct LogsView: View {
    @ObservedObject var prefs: AppPreferences
    @State private var logText = ""
    @State private var followTail = true
    @State private var filter = ""
    @State private var lineCount = 0
    @State private var loadError: String?
    @State private var lastKnownSize: UInt64 = .max
    @State private var lastKnownMTime: Date?
    @State private var isLoading = false

    private static let refreshTick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var logURL: URL { RDPLog.activeLogFileURL }

    private var displayedText: String {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty else {
            return logText.isEmpty ? L10n.t(.noLogYet) : logText
        }

        let needle = trimmedFilter.lowercased()
        let matched = logText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.lowercased().contains(needle) }
        return matched.isEmpty ? L10n.t(.noFilterMatch) : matched.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(lineCount == 0 ? L10n.t(.empty) : L10n.format(.linesCount, lineCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Toggle(L10n.t(.verbose), isOn: $prefs.devLog)
                    .toggleStyle(.checkbox)
                    .help(L10n.t(.verboseHelp))
                Toggle(L10n.t(.follow), isOn: $followTail)
                    .toggleStyle(.checkbox)

                Button {
                    loadLog(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.t(.refresh))

                Button {
                    revealLog()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(L10n.t(.reveal))
            }

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField(L10n.t(.filterPlaceholder), text: $filter)
                    .textFieldStyle(.roundedBorder)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t(.clear))
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LogTextView(text: displayedText, followTail: followTail)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadLog(force: true) }
        .onReceive(Self.refreshTick) { _ in loadLog(force: false) }
    }

    private func loadLog(force: Bool) {
        guard !isLoading else { return }
        let url = logURL
        isLoading = true

        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else {
                await MainActor.run {
                    logText = ""
                    lineCount = 0
                    lastKnownSize = .max
                    lastKnownMTime = nil
                    loadError = L10n.t(.logNotFound)
                    isLoading = false
                }
                return
            }

            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? UInt64 ?? 0
            let modificationDate = attributes?[.modificationDate] as? Date

            let shouldSkip = await MainActor.run {
                !force && size == lastKnownSize && modificationDate == lastKnownMTime
            }
            if shouldSkip {
                await MainActor.run { isLoading = false }
                return
            }

            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                await MainActor.run {
                    loadError = L10n.t(.logReadFailed)
                    isLoading = false
                }
                return
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let boundedText = lines.suffix(2_500).joined(separator: "\n")

            await MainActor.run {
                loadError = nil
                lineCount = lines.count
                lastKnownSize = size
                lastKnownMTime = modificationDate
                if logText != boundedText {
                    logText = boundedText
                }
                isLoading = false
            }
        }
    }

    private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }
}

private struct LogTextView: NSViewRepresentable {
    let text: String
    let followTail: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let changed = textView.string != text
        let followJustEnabled = followTail && !context.coordinator.followTail
        context.coordinator.followTail = followTail

        if changed {
            let wasNearBottom = isNearBottom(scrollView)
            textView.string = text
            if followTail || wasNearBottom {
                textView.scrollToEndOfDocument(nil)
            }
        } else if followJustEnabled {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        let visibleRect = scrollView.documentVisibleRect
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        return visibleRect.maxY >= documentHeight - 40
    }

    final class Coordinator {
        var textView: NSTextView?
        var followTail = false
    }
}
