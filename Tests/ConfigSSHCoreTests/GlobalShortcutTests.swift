import XCTest
@testable import ConfigSSHCore

final class GlobalShortcutTests: XCTestCase {
    private typealias S = GlobalShortcut

    func testDefaultAndPresetsAreValidAndDisplayInMacOrder() {
        XCTAssertEqual(S.default.display, "⌥⌘K")
        XCTAssertEqual(S.presets.map(\.display), ["⌥⌘K", "⌃⌥K", "⌥Space", "⌃⌥Space", "⌃⇧Space"])
        XCTAssertTrue(S.presets.allSatisfy { $0.problem == nil })
        XCTAssertEqual(S(keyCode: 111, modifiers: S.control | S.shift | S.option | S.command).display, "⌃⌥⇧⌘F12")
    }

    func testStorageRoundTripAndLegacyNames() {
        let custom = S(keyCode: 38, modifiers: S.command | S.shift)
        XCTAssertEqual(S.parse(custom.storageValue), custom)
        XCTAssertEqual(S.parse("optionCommandK"), S.default)
        XCTAssertEqual(S.parse("controlShiftSpace")?.display, "⌃⇧Space")
        XCTAssertNil(S.parse("key:999:256"), "unknown key code")
        XCTAssertNil(S.parse("key:40:0"), "no modifier")
        XCTAssertNil(S.parse("garbage"))
    }

    func testResolvedTreatsOffAsNothingAndUnsetAsDefault() {
        XCTAssertEqual(S.resolved(nil), .default)
        XCTAssertEqual(S.resolved(""), .default)
        XCTAssertNil(S.resolved("off"))
        XCTAssertEqual(S.resolved("not-a-shortcut"), .default, "unreadable values fall back instead of disabling the feature")
        XCTAssertEqual(S.resolved("controlOptionSpace")?.display, "⌃⌥Space")
    }

    func testModifierRules() {
        XCTAssertEqual(S(keyCode: 40, modifiers: 0).problem, .needsModifier)
        XCTAssertEqual(S(keyCode: 40, modifiers: S.shift).problem, .needsModifier, "Shift alone is not enough")
        XCTAssertEqual(S(keyCode: 40, modifiers: S.option).problem, .wouldBreakTyping, "⌥K would stop typing ˚")
        XCTAssertEqual(S(keyCode: 40, modifiers: S.option | S.shift).problem, .wouldBreakTyping)
        XCTAssertNil(S(keyCode: 49, modifiers: S.option).problem, "⌥Space types nothing")
        XCTAssertNil(S(keyCode: 111, modifiers: S.option).problem, "⌥F12 is fine")
        XCTAssertNil(S(keyCode: 40, modifiers: S.control).problem)
        XCTAssertEqual(S(keyCode: 250, modifiers: S.command).problem, .unknownKey)
    }

    func testSystemShortcutsAreRefused() {
        for (code, mods, name) in [(49, S.command, "聚焦搜索"), (48, S.command, "应用切换"), (12, S.command, "退出应用"),
                                   (49, S.control, "切换输入法")] as [(UInt32, UInt32, String)] {
            XCTAssertEqual(S(keyCode: code, modifiers: mods).problem, .reservedBySystem(name))
        }
        XCTAssertTrue(S(keyCode: 49, modifiers: S.command).problemDescription!.contains("聚焦搜索"))
    }

    func testCautionNotesOnlyForCrowdedCombinations() {
        XCTAssertNotNil(S(keyCode: 49, modifiers: S.control | S.option).cautionNote)
        XCTAssertNotNil(S(keyCode: 49, modifiers: S.option).cautionNote)
        XCTAssertNil(S.default.cautionNote)
    }

    func testModifierMaskDropsUnrelatedBits() {
        XCTAssertEqual(S(keyCode: 40, modifiers: S.command | 0x1_0000).modifiers, S.command)
    }
}
