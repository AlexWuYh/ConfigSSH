import Foundation

/// A system-wide key combination, stored with Carbon modifier flags so it can be passed straight to
/// `RegisterEventHotKey`. Parsing, validation and display live here so they can be tested without
/// touching the keyboard.
package struct GlobalShortcut: Equatable, Sendable {
    package static let command: UInt32 = 256
    package static let shift: UInt32 = 512
    package static let option: UInt32 = 2048
    package static let control: UInt32 = 4096
    package static let modifierMask: UInt32 = command | shift | option | control

    package let keyCode: UInt32
    package let modifiers: UInt32

    package init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// ⌥⌘K: unused by a default macOS install, unlike ⌃Space / ⌃⌥Space (input sources).
    package static let `default` = GlobalShortcut(keyCode: 40, modifiers: command | option)

    package static let presets: [GlobalShortcut] = [
        .default,
        GlobalShortcut(keyCode: 40, modifiers: control | option),
        GlobalShortcut(keyCode: 49, modifiers: option),
        GlobalShortcut(keyCode: 49, modifiers: control | option),
        GlobalShortcut(keyCode: 49, modifiers: control | shift)
    ]

    // MARK: Storage

    package static let offValue = "off"

    /// `off`, a legacy preset name, or `key:<keyCode>:<carbonModifiers>`.
    package var storageValue: String { "key:\(keyCode):\(modifiers)" }

    /// What the app should register for a saved value: nothing when off, the default when nothing
    /// (or something unreadable) was saved.
    package static func resolved(_ stored: String?) -> GlobalShortcut? {
        guard let stored, !stored.isEmpty else { return .default }
        if stored == offValue { return nil }
        return parse(stored) ?? .default
    }

    package static func parse(_ raw: String) -> GlobalShortcut? {
        switch raw {
        case "optionCommandK": return presets[0]
        case "controlOptionK": return presets[1]
        case "optionSpace": return presets[2]
        case "controlOptionSpace": return presets[3]
        case "controlShiftSpace": return presets[4]
        default: break
        }
        let parts = raw.split(separator: ":")
        guard parts.count == 3, parts[0] == "key",
              let code = UInt32(parts[1]), let mods = UInt32(parts[2]),
              code < 200, Self.keyNames[code] != nil else { return nil }
        let shortcut = GlobalShortcut(keyCode: code, modifiers: mods)
        return shortcut.problem == nil ? shortcut : nil
    }

    // MARK: Display

    package var display: String { keyParts.joined() }

    /// The shortcut as separate keys in macOS order, for drawing keycaps: each modifier is one
    /// part and the main key is one part, so "Space" stays a single word instead of five letters.
    package var keyParts: [String] {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("⌃") }
        if modifiers & Self.option != 0 { parts.append("⌥") }
        if modifiers & Self.shift != 0 { parts.append("⇧") }
        if modifiers & Self.command != 0 { parts.append("⌘") }
        parts.append(Self.keyNames[keyCode] ?? "?")
        return parts
    }

    // MARK: Validation

    package enum Problem: Equatable, Sendable {
        case needsModifier
        case wouldBreakTyping
        case reservedBySystem(String)
        case unknownKey
    }

    /// Option-only (and Option+Shift) combinations are fine on keys that do not type a character.
    private var typesCharacter: Bool {
        guard let name = Self.keyNames[keyCode] else { return true }
        return name.count == 1 || name == "Delete" || name == "Return" || name == "Tab"
    }

    /// Why this combination cannot be used, or nil.
    package var problem: Problem? {
        guard Self.keyNames[keyCode] != nil else { return .unknownKey }
        let strong = modifiers & (Self.command | Self.control)
        let hasOption = modifiers & Self.option != 0
        if modifiers & (Self.command | Self.control | Self.option) == 0 { return .needsModifier }
        if strong == 0 && hasOption && typesCharacter { return .wouldBreakTyping }
        if let owner = Self.reserved[Self.reservedKey(keyCode, modifiers)] { return .reservedBySystem(owner) }
        return nil
    }

    package var problemDescription: String? {
        switch problem {
        case .none: return nil
        case .needsModifier: return "至少要包含 ⌘、⌃、⌥ 中的一个修饰键。"
        case .wouldBreakTyping: return "只用 ⌥ 加字符键会让这个键在所有应用里都打不出原来的字符，请加上 ⌘ 或 ⌃，或改用空格、方向键、F 键。"
        case .reservedBySystem(let owner): return "与 macOS 的“\(owner)”冲突，请换一个组合。"
        case .unknownKey: return "不支持这个按键。"
        }
    }

    /// Combinations that are usually taken without being an error to register: the registration may
    /// succeed and the other owner then stops working.
    package var cautionNote: String? {
        switch (keyCode, modifiers) {
        case (49, Self.control | Self.option): return "与系统“选择输入法菜单中的下一个输入法”默认快捷键相同。"
        case (49, Self.control | Self.shift): return "部分输入法和编辑器也使用此组合。"
        case (49, Self.option): return "Alfred 等启动器常用此组合。"
        default: return nil
        }
    }

    private static func reservedKey(_ code: UInt32, _ modifiers: UInt32) -> UInt64 {
        (UInt64(code) << 16) | UInt64(modifiers)
    }

    private static let reserved: [UInt64: String] = {
        let c = command, s = shift, o = option, k = control
        let items: [(UInt32, UInt32, String)] = [
            (49, c, "聚焦搜索"), (49, c | o, "访达搜索"), (49, k, "切换输入法"), (49, k | c, "表情与符号"),
            (48, c, "应用切换"), (48, c | s, "应用切换"), (12, c, "退出应用"), (13, c, "关闭窗口"),
            (4, c, "隐藏应用"), (46, c, "最小化窗口"), (43, c, "设置"), (53, c | o, "强制退出"),
            (20, c | s, "屏幕截图"), (21, c | s, "屏幕截图"), (23, c | s, "屏幕截图"),
            (12, k | c, "锁定屏幕"), (3, k | c, "进入全屏")
        ]
        return Dictionary(uniqueKeysWithValues: items.map { (reservedKey($0.0, $0.1), $0.2) })
    }()

    // MARK: Key names (ANSI keyboard key codes)

    package static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`",
        36: "Return", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
