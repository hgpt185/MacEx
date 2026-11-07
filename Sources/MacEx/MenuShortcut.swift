import AppKit

struct MenuShortcut: Identifiable {
    var id: String { section + ":" + title + ":" + keys }
    let section: String
    let title: String
    let keys: String

    @MainActor static func read(_ menu: NSMenu, section: String = "") -> [MenuShortcut] {
        menu.items.flatMap { item -> [MenuShortcut] in
            guard !item.isHidden, !item.isAlternate else { return [] }
            if let submenu = item.submenu { return read(submenu, section: item.title) }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { return [] }
            var modifiers = item.keyEquivalentModifierMask
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            let flags = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            let key = ["\u{8}": "⌫", "\u{7f}": "⌫", " ": "Space", "\r": "Return", "\u{1b}": "Esc", "\u{f702}": "←", "\u{f703}": "→"][item.keyEquivalent] ?? item.keyEquivalent.uppercased()
            return [MenuShortcut(section: section, title: item.title, keys: flags.filter { modifiers.contains($0.0) }.map(\.1).joined() + key)]
        }
    }

    @MainActor static func hint(for title: String) -> String? {
        let aliases = ["New Folder…": "New Folder", "Go to Folder…": "Go to Folder", "Switch to Light appearance": "Switch Look", "Switch to Dark appearance": "Switch Look"]
        guard let menu = NSApp?.mainMenu else { return nil }
        return read(menu).first { $0.title == (aliases[title] ?? title) }?.keys
    }
}
