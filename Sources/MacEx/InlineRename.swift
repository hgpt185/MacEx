import AppKit
import Combine
import MacExCore

/// Edits the existing native cell field, preserving AppKit's table/collection accessibility hierarchy.
@MainActor final class InlineRenameEditor: NSObject, NSTextFieldDelegate {
    @MainActor private struct FieldState {
        let name: String
        let editable: Bool, selectable: Bool, bezeled: Bool, bordered: Bool, background: Bool
        let focus: NSFocusRingType, lines: Int
        let identifier: String?, label: String?, help: String?
        let delegate: (any NSTextFieldDelegate)?
        init(_ field: NSTextField) {
            name = field.stringValue; editable = field.isEditable; selectable = field.isSelectable
            bezeled = field.isBezeled; bordered = field.isBordered; background = field.drawsBackground
            focus = field.focusRingType; lines = field.maximumNumberOfLines
            identifier = field.accessibilityIdentifier(); label = field.accessibilityLabel(); help = field.accessibilityHelp()
            delegate = field.delegate
        }
        func restore(_ field: NSTextField) {
            field.stringValue = name; field.isEditable = editable; field.isSelectable = selectable
            field.isBezeled = bezeled; field.isBordered = bordered; field.drawsBackground = background
            field.focusRingType = focus; field.maximumNumberOfLines = lines
            field.setAccessibilityIdentifier(identifier); field.setAccessibilityLabel(label); field.setAccessibilityHelp(help)
            // Clear the editing override so AppKit derives the read-only label role again.
            field.setAccessibilityRole(nil); field.delegate = delegate
        }
    }
    private weak var model: BrowserModel?
    private weak var host: NSView?
    private weak var accessibilityContainer: NSView?
    private var url: URL?
    private var field: NSTextField?
    private var state: FieldState?
    private var errorLabel: NSTextField?
    private var scrollObserver: AnyCancellable?

    func begin(_ entry: FileEntry, label: NSTextField, in host: NSView, model: BrowserModel, accessibilityContainer: NSView? = nil) {
        end()
        self.model = model; self.host = host; self.accessibilityContainer = accessibilityContainer; url = entry.url
        field = label; state = FieldState(label)
        label.isEditable = true; label.isSelectable = true; label.isBezeled = true; label.drawsBackground = true
        label.focusRingType = .exterior; label.maximumNumberOfLines = 1; label.delegate = self
        label.setAccessibilityRole(.textField); label.setAccessibilityLabel("Rename " + entry.name)
        label.setAccessibilityIdentifier("inline-rename")
        let error = NSTextField(labelWithString: "")
        error.font = .systemFont(ofSize: 9); error.textColor = .systemRed; error.alignment = label.alignment
        error.drawsBackground = true; error.backgroundColor = .textBackgroundColor; error.isHidden = true
        error.setAccessibilityIdentifier("inline-rename-error")
        label.superview?.addSubview(error); errorLabel = error
        // Icon tiles normally present one accessibility cell. During editing they expose their native controls.
        accessibilityContainer?.setAccessibilityRole(.group)
        accessibilityContainer?.setAccessibilityChildren([label, error])
        if let clip = host.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip)
                .sink { [weak model] _ in model?.cancelRename() }
        }
        host.window?.makeFirstResponder(label)
        let name = entry.name as NSString
        let ext = entry.isFolder ? "" : (entry.name as NSString).pathExtension
        let basenameLength = ext.isEmpty ? name.length : max(1, name.length - (ext as NSString).length - 1)
        (label.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: basenameLength))
        NSAccessibility.post(element: host, notification: .layoutChanged)
    }
    func end() {
        scrollObserver = nil
        let edited = field?.currentEditor() != nil
        field?.delegate = nil
        // End native editing before restoring the old value so cancelled editor text cannot overwrite it.
        if edited, let host { host.window?.makeFirstResponder(host) }
        if let field { state?.restore(field); NSAccessibility.post(element: field, notification: .valueChanged) }
        errorLabel?.removeFromSuperview()
        accessibilityContainer?.setAccessibilityChildren(nil); accessibilityContainer?.setAccessibilityRole(.cell)
        if field != nil, let host { NSAccessibility.post(element: host, notification: .layoutChanged) }
        field = nil; state = nil; errorLabel = nil; url = nil; accessibilityContainer = nil
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { model?.cancelRename(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
            guard let url, let field else { return true }
            if let message = model?.rename(url, to: field.stringValue) {
                field.setAccessibilityHelp(message)
                errorLabel?.stringValue = message; errorLabel?.toolTip = message; errorLabel?.isHidden = false
                errorLabel?.setAccessibilityLabel(message)
                let rect = field.frame
                let y = field.superview?.isFlipped == true ? rect.maxY + 1 : max(0, rect.minY - 11)
                errorLabel?.frame = NSRect(x: rect.minX, y: y, width: rect.width, height: 11)
                NSAccessibility.post(element: field, notification: .layoutChanged)
            }
            return true
        }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) { model?.cancelRename() }
}

/// A second completed name click starts editing only after the double-click opening interval has elapsed.
struct SlowRenameClick {
    private var last: (URL, TimeInterval)?
    mutating func reset() { last = nil }
    mutating func record(_ url: URL, at timestamp: TimeInterval) { last = (url, timestamp) }
    func shouldRename(_ url: URL, at timestamp: TimeInterval) -> Bool {
        guard let last, last.0 == url else { return false }
        let elapsed = timestamp - last.1
        return elapsed > NSEvent.doubleClickInterval && elapsed < 2
    }
}
