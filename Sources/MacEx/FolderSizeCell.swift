import AppKit
import MacExCore

/// A table cell owns a subscription only while displayed. Reuse invalidates old completions.
@MainActor final class FolderSizeCell: NSTableCellView {
    private let countField = NSTextField(labelWithString: "")
    private var token: FolderSizes.Token?
    private var entry: FileEntry?
    private var generation = UUID()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let bytes = NSTextField(labelWithString: "")
        bytes.font = .systemFont(ofSize: 11); countField.font = .systemFont(ofSize: 9)
        for field in [bytes, countField] {
            field.translatesAutoresizingMaskIntoConstraints = false; field.alignment = .right
            field.textColor = .secondaryLabelColor; field.lineBreakMode = .byTruncatingTail
            addSubview(field)
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7).isActive = true
        }
        bytes.topAnchor.constraint(equalTo: topAnchor, constant: 3).isActive = true
        countField.topAnchor.constraint(equalTo: bytes.bottomAnchor, constant: 1).isActive = true
        textField = bytes
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ entry: FileEntry) {
        FolderSizes.shared.cancel(token); token = nil; generation = UUID(); self.entry = entry
        textField?.stringValue = "Calculating…"; countField.stringValue = ""
        toolTip = entry.url.path
        if window != nil { request() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FolderSizes.shared.cancel(token); token = nil; generation = UUID()
        if window != nil { request() }
    }
    private func request() {
        guard let entry else { return }
        let expected = generation
        token = FolderSizes.shared.request(entry) { [weak self] result in
            guard let self, generation == expected else { return }
            guard let result else {
                textField?.stringValue = "Unavailable"; countField.stringValue = ""; return
            }
            let size = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
            let count = result.limitReached ? "50,000+ items" : "\(result.itemCount.formatted()) \(result.itemCount == 1 ? "item" : "items")"
            textField?.stringValue = (result.isPartial ? "≥ " : "") + size
            countField.stringValue = count + (result.isPartial && !result.limitReached ? " (partial)" : "")
            toolTip = "\(entry.url.path)\n\(size) · \(count)\(result.isPartial ? " · Partial total; some entries were skipped or the scan limit was reached." : "")"
            setAccessibilityLabel("\(size), \(count)\(result.isPartial ? ", partial total" : "")")
        }
    }
}
