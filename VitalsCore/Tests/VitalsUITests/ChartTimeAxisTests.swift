import Foundation
import Testing
@testable import VitalsUI

@Suite("Chart time axis")
struct ChartTimeAxisTests {

    // MARK: ChartSeries timestamps

    @Test("a series without timestamps keeps every value and reports no time")
    func untimestampedSeriesIsUnchanged() {
        let series = ChartSeries(name: "CPU", values: [0.1, 0.2, 0.3])
        #expect(series.values.count == 3)
        #expect(series.timestamps.isEmpty)
    }

    @Test("values and timestamps of equal length are both kept whole")
    func matchedLengthsAreKept() {
        let series = ChartSeries(name: "CPU", values: [0.1, 0.2], timestamps: [10, 11])
        #expect(series.values == [0.1, 0.2])
        #expect(series.timestamps == [10, 11])
    }

    @Test("more timestamps than values truncates both, never pads")
    func extraTimestampsAreTruncated() {
        let series = ChartSeries(name: "CPU", values: [0.1, 0.2], timestamps: [10, 11, 12, 13])
        #expect(series.values == [0.1, 0.2])
        #expect(series.timestamps == [10, 11])
    }

    @Test("more values than timestamps truncates both, never pads")
    func extraValuesAreTruncated() {
        // Padding the missing timestamps would claim we know when samples were
        // taken that we do not.
        let series = ChartSeries(name: "CPU", values: [0.1, 0.2, 0.3, 0.4], timestamps: [10, 11])
        #expect(series.values == [0.1, 0.2])
        #expect(series.timestamps == [10, 11])
    }

    // MARK: Gap threshold

    @Test("fewer than two timestamps cannot establish a threshold")
    func tooFewTimestampsYieldNoThreshold() {
        #expect(ChartGeometry.gapThreshold(for: []) == nil)
        #expect(ChartGeometry.gapThreshold(for: [10]) == nil)
    }

    @Test("a steady cadence yields a threshold above that cadence")
    func steadyCadenceYieldsThreshold() throws {
        let threshold = try #require(ChartGeometry.gapThreshold(for: [10, 11, 12, 13, 14]))
        #expect(threshold == 3.0)
    }

    @Test("one huge gap does not drag the threshold up and hide the others")
    func medianResistsAnOutlier() throws {
        // The mean interval here is ~2000s; a mean-based threshold would treat
        // every real gap as continuous. The median stays at 1s.
        var timestamps: [TimeInterval] = (0..<20).map(TimeInterval.init)
        timestamps.append(20_000)
        timestamps.append(20_001)

        let threshold = try #require(ChartGeometry.gapThreshold(for: timestamps))
        #expect(threshold == 3.0)
    }

    @Test("non-advancing timestamps are ignored rather than yielding a zero threshold")
    func nonAdvancingTimestampsIgnored() {
        #expect(ChartGeometry.gapThreshold(for: [10, 10, 10]) == nil)
    }

    // MARK: Segments

    @Test("continuous samples form a single segment")
    func continuousSamplesAreOneSegment() {
        let segments = ChartGeometry.segments(timestamps: [10, 11, 12, 13], threshold: 3)
        #expect(segments == [0..<4])
    }

    @Test("a gap splits the run in two")
    func gapSplitsRun() {
        let segments = ChartGeometry.segments(timestamps: [10, 11, 500, 501], threshold: 3)
        #expect(segments == [0..<2, 2..<4])
    }

    @Test("several gaps split into several segments")
    func severalGapsSplitSeveralTimes() {
        let segments = ChartGeometry.segments(
            timestamps: [10, 11, 500, 501, 900, 901, 902],
            threshold: 3
        )
        #expect(segments == [0..<2, 2..<4, 4..<7])
    }

    @Test("a gap immediately after the first sample leaves a single-sample segment")
    func gapAtStartLeavesLoneSample() {
        let segments = ChartGeometry.segments(timestamps: [10, 900, 901, 902], threshold: 3)
        #expect(segments == [0..<1, 1..<4])
    }

    @Test("a gap before the last sample leaves a single-sample segment at the end")
    func gapAtEndLeavesLoneSample() {
        let segments = ChartGeometry.segments(timestamps: [10, 11, 12, 900], threshold: 3)
        #expect(segments == [0..<3, 3..<4])
    }

    @Test("a single timestamp is one segment")
    func singleTimestampIsOneSegment() {
        #expect(ChartGeometry.segments(timestamps: [10], threshold: 3) == [0..<1])
    }

    @Test("no timestamps means no segments")
    func noTimestampsMeansNoSegments() {
        #expect(ChartGeometry.segments(timestamps: [], threshold: 3).isEmpty)
    }

    @Test("segments cover every index exactly once")
    func segmentsCoverEveryIndex() {
        let timestamps: [TimeInterval] = [10, 11, 500, 501, 502, 900]
        let covered = ChartGeometry.segments(timestamps: timestamps, threshold: 3)
            .flatMap { Array($0) }
        #expect(covered == Array(0..<timestamps.count))
    }

    // MARK: Segments for a series

    @Test("an untimestamped series renders as one unbroken run, exactly as before")
    func untimestampedSeriesIsOneSegment() {
        let series = ChartSeries(name: "CPU", values: [0.1, 0.2, 0.3])
        #expect(ChartGeometry.segments(for: series) == [0..<3])
    }

    @Test("a timestamped series with a gap breaks")
    func timestampedSeriesBreaks() {
        let series = ChartSeries(
            name: "CPU",
            values: [0.1, 0.2, 0.3, 0.4],
            timestamps: [10, 11, 900, 901]
        )
        #expect(ChartGeometry.segments(for: series) == [0..<2, 2..<4])
    }

    @Test("an empty series has no segments")
    func emptySeriesHasNoSegments() {
        #expect(ChartGeometry.segments(for: ChartSeries(name: "CPU", values: [])).isEmpty)
    }

    // MARK: Relative age

    @Test("the newest sample reads as now, not as zero seconds")
    func newestSampleReadsAsNow() {
        #expect(ChartGeometry.relativeAge(of: 100, now: 100) == "now")
        #expect(ChartGeometry.relativeAge(of: 100, now: 100.4) == "now")
    }

    @Test("seconds, minutes and hours are phrased for a rolling chart")
    func agePhrasing() {
        #expect(ChartGeometry.relativeAge(of: 100, now: 112) == "12s ago")
        #expect(ChartGeometry.relativeAge(of: 100, now: 280) == "3m ago")
        #expect(ChartGeometry.relativeAge(of: 100, now: 3_700) == "1h ago")
        #expect(ChartGeometry.relativeAge(of: 100, now: 4_000) == "1h 5m ago")
    }

    @Test("just under a minute stays in seconds")
    func justUnderAMinuteStaysInSeconds() {
        #expect(ChartGeometry.relativeAge(of: 100, now: 159) == "59s ago")
    }
}
