import Foundation
import Testing
@testable import SystemMetrics

@Suite("Memory hardware")
struct MemoryHardwareTests {

    private func fixture(_ name: String) throws -> Data {
        // `.copy("Fixtures")` preserves the directory, so the subdirectory must
        // be named explicitly rather than folded into the resource name.
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test("parses Apple Silicon type and manufacturer from a real capture")
    func parsesAppleSilicon() throws {
        let hardware = try MemoryHardwareParser.parse(
            profilerJSON: fixture("SPMemoryDataType-m2pro"),
            totalBytes: 17_179_869_184,
            isUnified: true,
            brand: "Apple M2 Pro"
        )
        #expect(hardware.type == "LPDDR5")
        #expect(hardware.manufacturer == "Hynix")
        #expect(hardware.isUnified == true)
        #expect(hardware.totalBytes == 17_179_869_184)
    }

    @Test("Apple Silicon reports no memory clock rather than inventing one")
    func appleSiliconHasNoSpeed() throws {
        let hardware = try MemoryHardwareParser.parse(
            profilerJSON: fixture("SPMemoryDataType-m2pro"),
            totalBytes: 17_179_869_184,
            isUnified: true,
            brand: "Apple M2 Pro"
        )
        #expect(hardware.speedMHz == nil)
        #expect(hardware.slots.isEmpty)
    }

    @Test("Apple Silicon reports spec bandwidth from the SoC table")
    func appleSiliconReportsBandwidth() throws {
        let hardware = try MemoryHardwareParser.parse(
            profilerJSON: fixture("SPMemoryDataType-m2pro"),
            totalBytes: 17_179_869_184,
            isUnified: true,
            brand: "Apple M2 Pro"
        )
        #expect(hardware.peakBandwidthGBs == 200)
    }

    @Test("parses Intel DIMM slots with real speeds")
    func parsesIntelSlots() throws {
        let hardware = try MemoryHardwareParser.parse(
            profilerJSON: fixture("SPMemoryDataType-intel"),
            totalBytes: 34_359_738_368,
            isUnified: false,
            brand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"
        )
        #expect(hardware.slots.count == 2)
        #expect(hardware.slots[0].name == "BANK 0/ChannelA-DIMM0")
        #expect(hardware.slots[0].speedMHz == 2667)
        #expect(hardware.slots[0].partNumber == "MTA16ATF2G64HZ-2G6E1")
        #expect(hardware.speedMHz == 2667)
        #expect(hardware.isUnified == false)
    }

    @Test("Intel machines have no SoC bandwidth figure")
    func intelHasNoBandwidth() throws {
        let hardware = try MemoryHardwareParser.parse(
            profilerJSON: fixture("SPMemoryDataType-intel"),
            totalBytes: 34_359_738_368,
            isUnified: false,
            brand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"
        )
        #expect(hardware.peakBandwidthGBs == nil)
    }

    @Test("known SoCs resolve to their published bandwidth")
    func knownSoCBandwidth() {
        #expect(SoCBandwidth.peakGBs(forBrand: "Apple M1") == 68.25)
        #expect(SoCBandwidth.peakGBs(forBrand: "Apple M1 Max") == 400)
        #expect(SoCBandwidth.peakGBs(forBrand: "Apple M2 Pro") == 200)
        #expect(SoCBandwidth.peakGBs(forBrand: "Apple M3 Pro") == 150)
    }

    @Test("an unrecognised SoC yields nil rather than a guess")
    func unknownSoCYieldsNil() {
        #expect(SoCBandwidth.peakGBs(forBrand: "Apple M9 Ultra Extreme") == nil)
        #expect(SoCBandwidth.peakGBs(forBrand: "") == nil)

        // Deliberate, not an oversight: the two M3 Max binnings publish
        // different bandwidth (300 and 400 GB/s) behind one brand string, so
        // there is no honest single answer. Do not add it to the table.
        #expect(SoCBandwidth.peakGBs(forBrand: "Apple M3 Max") == nil)
    }

    @Test("malformed JSON throws rather than returning zeroed hardware")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try MemoryHardwareParser.parse(
                profilerJSON: Data("not json".utf8),
                totalBytes: 0,
                isUnified: true,
                brand: "Apple M2 Pro"
            )
        }
    }
}
