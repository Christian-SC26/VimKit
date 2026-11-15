import Testing
@testable import VimCore

struct HIDKeyEventTests {
    @Test func lettersCarryTheirPhysicalKey() throws {
        let j = try #require(VimKeyEvent(hidUsage: 13, characters: "j", charactersIgnoringModifiers: "j"))
        #expect(j.key == "j" && j.code == "KeyJ")
        let russian = try #require(VimKeyEvent(hidUsage: 13, characters: "о", charactersIgnoringModifiers: "о"))
        #expect(russian.key == "о" && russian.code == "KeyJ")
    }

    @Test func controlUsesThePlainKey() throws {
        let event = try #require(VimKeyEvent(hidUsage: 7, characters: "\u{4}", charactersIgnoringModifiers: "d", control: true))
        #expect(event.key == "d" && event.control)
    }

    @Test func specialKeys() {
        #expect(VimKeyEvent(hidUsage: 41, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}")?.key == VimKeyEvent.escape)
        #expect(VimKeyEvent(hidUsage: 42, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}")?.key == VimKeyEvent.backspace)
        #expect(VimKeyEvent(hidUsage: 82, characters: "UIKeyInputUpArrow", charactersIgnoringModifiers: "UIKeyInputUpArrow")?.key == VimKeyEvent.arrowUp)
        #expect(VimKeyEvent(hidUsage: 60, characters: "", charactersIgnoringModifiers: "")?.key == "F3")
    }

    @Test func shiftedPunctuationAndModifierOnlyPresses() {
        #expect(VimKeyEvent(hidUsage: 54, characters: "<", charactersIgnoringModifiers: ",", shift: true)?.code == "Key<")
        #expect(VimKeyEvent(hidUsage: 225, characters: "", charactersIgnoringModifiers: "", shift: true) == nil)
    }

    @Test @MainActor func hidEventsDriveTheEngine() throws {
        let runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        let engine = VimEngine(text: "one two", runtime: runtime)
        for (usage, character) in [(7, "d"), (26, "w")] {
            let event = try #require(VimKeyEvent(hidUsage: usage, characters: character, charactersIgnoringModifiers: character))
            #expect(engine.handle(event))
        }
        #expect(engine.text == "two")
    }
}
