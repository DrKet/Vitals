import Foundation

/// Reads temperatures through `IOHIDEventSystemClient`, a private and
/// undocumented framework interface. There is no header to import against,
/// so every symbol below is resolved with `dlsym` rather than linked, and the
/// exact signatures, the matching dictionary, the event type (`15`), and the
/// field id (`15 << 16`) are ported verbatim from
/// `scripts/spike-sensors.swift`, which produced real readings on this
/// machine — they are not reconstructed from memory.
///
/// `dlsym` (rather than linking) means a future OS that renames or drops a
/// symbol degrades this provider to `.unavailable`, not a launch-time crash.
public struct IOHIDSensorProvider: SensorProviding, Sendable {

    // MARK: - Private C signatures

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject?, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject?, Int32) -> Double

    /// The resolved function pointers, or the reason resolution failed.
    ///
    /// `Unmanaged<AnyObject>` and the C function pointer types above are not
    /// themselves `Sendable`, but they are plain addresses into a
    /// system framework loaded once and never mutated, so wrapping them here
    /// is safe and lets the struct as a whole satisfy `SensorProviding`.
    private struct Symbols: @unchecked Sendable {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloat: GetFloatFn
    }

    /// The event type the spike found carries temperature, and the field id
    /// derived from it (`type << 16`) at which `IOHIDEventGetFloatValue`
    /// returns the value for that type.
    private static let temperatureEventType: Int64 = 15
    private static var temperatureFieldID: Int32 { Int32(temperatureEventType << 16) }

    private let symbols: Symbols?
    private let unavailableReason: String?

    public var availability: MetricAvailability {
        if let unavailableReason {
            return .unavailable(reason: unavailableReason)
        }
        return .available
    }

    public init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            self.symbols = nil
            self.unavailableReason = "Could not open IOKit.framework"
            return
        }

        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(iokit, name) }

        let names = [
            "IOHIDEventSystemClientCreate",
            "IOHIDEventSystemClientSetMatching",
            "IOHIDEventSystemClientCopyServices",
            "IOHIDServiceClientCopyProperty",
            "IOHIDServiceClientCopyEvent",
            "IOHIDEventGetFloatValue",
        ]
        let pointers = names.map(sym)
        if let missingIndex = pointers.firstIndex(where: { $0 == nil }) {
            self.symbols = nil
            self.unavailableReason = "Missing IOKit symbol: \(names[missingIndex])"
            return
        }

        self.symbols = Symbols(
            create: unsafeBitCast(pointers[0]!, to: CreateFn.self),
            setMatching: unsafeBitCast(pointers[1]!, to: SetMatchingFn.self),
            copyServices: unsafeBitCast(pointers[2]!, to: CopyServicesFn.self),
            copyProperty: unsafeBitCast(pointers[3]!, to: CopyPropertyFn.self),
            copyEvent: unsafeBitCast(pointers[4]!, to: CopyEventFn.self),
            getFloat: unsafeBitCast(pointers[5]!, to: GetFloatFn.self)
        )
        self.unavailableReason = nil
    }

    public func readings() -> [SensorReading] {
        guard let symbols else { return [] }
        guard let client = symbols.create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }

        // The spike's matching dictionary: usage page 0xff00 is where the
        // temperature-bearing services live.
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00]
        _ = symbols.setMatching(client, matching as CFDictionary)

        guard let servicesRef = symbols.copyServices(client) else { return [] }
        let services = servicesRef.takeRetainedValue() as [AnyObject]

        var raw: [(name: String, celsius: Double)] = []
        for service in services {
            let name = (symbols.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String)
                ?? "(unnamed)"
            guard let eventRef = symbols.copyEvent(
                service, Self.temperatureEventType, 0, 0
            ) else { continue }
            let value = symbols.getFloat(eventRef.takeRetainedValue(), Self.temperatureFieldID)
            // Discard non-finite values (e.g. Int(Double.infinity) traps
            // downstream); keep zero — a legitimate zero is still a reading,
            // and the spike's own first probe was wrong to filter it out.
            guard value.isFinite else { continue }
            raw.append((name: name, celsius: value))
        }
        return Self.aggregate(raw)
    }

    /// Groups raw per-sensor readings by name, keeping the hottest.
    ///
    /// The spike proved sensors carry no unique identity, so a name is the
    /// finest grain that can be honestly labelled. Indexing duplicates as
    /// `#1`/`#2` was rejected: service order is stable within one process, but
    /// nothing establishes that `#1` is the same physical sensor across
    /// launches, so the index would be a distinction this code invented.
    ///
    /// Sorted by name so the order cannot drift between runs.
    ///
    /// Every group starts life with `count: 1` from its first entry and only
    /// ever increments, so `sensorCount` cannot be produced below 1 — there
    /// is no code path that emits a `SensorReading` from an empty group, and
    /// `readings()` filters to finite values before this is ever called.
    static func aggregate(_ raw: [(name: String, celsius: Double)]) -> [SensorReading] {
        var grouped: [String: (hottest: Double, count: Int)] = [:]
        for entry in raw {
            if let existing = grouped[entry.name] {
                grouped[entry.name] = (Swift.max(existing.hottest, entry.celsius), existing.count + 1)
            } else {
                grouped[entry.name] = (entry.celsius, 1)
            }
        }
        return grouped
            .map { SensorReading(name: $0.key, kind: .temperatureCelsius, value: $0.value.hottest, sensorCount: $0.value.count) }
            .sorted { $0.name < $1.name }
    }
}
