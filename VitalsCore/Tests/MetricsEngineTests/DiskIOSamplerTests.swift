import Testing
@testable import MetricsEngine

@Suite("Disk IO")
struct DiskIOSamplerTests {

    @Test("diskIO is one of the standard series")
    func diskIOIsAStandardSeries() {
        #expect(SeriesKey.allCases.contains(.diskIO))
    }
}
