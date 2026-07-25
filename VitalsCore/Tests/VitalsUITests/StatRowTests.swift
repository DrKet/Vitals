import Testing
@testable import VitalsUI

@Suite("Stat row")
struct StatRowTests {

    @Test("a nil value displays as the word 'Unavailable'")
    func nilValueDisplaysAsUnavailable() {
        #expect(StatRow.displayValue(nil) == "Unavailable")
    }

    @Test("a non-nil value passes through unchanged")
    func nonNilValuePassesThrough() {
        #expect(StatRow.displayValue("3.49 GHz") == "3.49 GHz")
    }

    @Test("an empty string is a real value, not treated as absence")
    func emptyStringIsNotAbsence() {
        // Only `nil` means "no reading." An empty string is a distinct,
        // if unusual, non-nil value and must not be rewritten to "Unavailable".
        #expect(StatRow.displayValue("") == "")
    }
}
