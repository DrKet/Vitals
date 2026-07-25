import Testing
@testable import MetricsEngine

@Suite("RingBuffer")
struct RingBufferTests {

    @Test("returns elements in insertion order")
    func preservesOrder() {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 1...3 { buffer.append(value) }
        #expect(buffer.elements == [1, 2, 3])
    }

    @Test("drops the oldest element when full")
    func dropsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.count == 3)
    }

    @Test("reports fullness")
    func reportsFullness() {
        var buffer = RingBuffer<Int>(capacity: 2)
        #expect(buffer.isFull == false)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.isFull == true)
    }

    @Test("wraps repeatedly without corrupting order")
    func wrapsRepeatedly() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 1...100 { buffer.append(value) }
        #expect(buffer.elements == [97, 98, 99, 100])
    }

    @Test("removeAll empties the buffer")
    func removeAllEmpties() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.removeAll()
        #expect(buffer.elements.isEmpty)
        #expect(buffer.count == 0)
    }

    @Test("a capacity of zero accepts appends and stays empty")
    func zeroCapacityStaysEmpty() {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(1)
        #expect(buffer.elements.isEmpty)
    }

    @Test("holds ten minutes of one-hertz samples")
    func holdsTenMinutes() {
        var buffer = RingBuffer<Int>(capacity: 600)
        for value in 1...1000 { buffer.append(value) }
        #expect(buffer.count == 600)
        #expect(buffer.elements.first == 401)
        #expect(buffer.elements.last == 1000)
    }
}
