import Foundation

// Spike part 2. Part 1 proved the API returns plausible numbers. Plausible is
// not the same as real: a stub, a misread field, or a stale cache would also
// look like "37.1 degrees". The question this answers is whether the values
// TRACK REALITY — they must climb under CPU load and fall afterwards.
//
// Also fixes part 1's own blind spot: it discarded zero-valued readings, which
// would hide an idle fan sitting legitimately at 0 RPM.

guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
    print("FAIL: dlopen IOKit"); exit(1)
}
func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(iokit, n) }

typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
typealias SetMatchingFn = @convention(c) (AnyObject?, CFDictionary?) -> Int32
typealias CopyServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
typealias CopyPropertyFn = @convention(c) (AnyObject?, CFString) -> Unmanaged<AnyObject>?
typealias CopyEventFn = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
typealias GetFloatFn = @convention(c) (AnyObject?, Int32) -> Double

let create = unsafeBitCast(sym("IOHIDEventSystemClientCreate")!, to: CreateFn.self)
let setMatching = unsafeBitCast(sym("IOHIDEventSystemClientSetMatching")!, to: SetMatchingFn.self)
let copyServices = unsafeBitCast(sym("IOHIDEventSystemClientCopyServices")!, to: CopyServicesFn.self)
let copyProperty = unsafeBitCast(sym("IOHIDServiceClientCopyProperty")!, to: CopyPropertyFn.self)
let copyEvent = unsafeBitCast(sym("IOHIDServiceClientCopyEvent")!, to: CopyEventFn.self)
let getFloat = unsafeBitCast(sym("IOHIDEventGetFloatValue")!, to: GetFloatFn.self)

let client = create(kCFAllocatorDefault)!.takeRetainedValue()
let matching: [String: Any] = ["PrimaryUsagePage": 0xff00]
_ = setMatching(client, matching as CFDictionary)
let services = copyServices(client)!.takeRetainedValue() as [AnyObject]

func property(_ s: AnyObject, _ k: String) -> Any? { copyProperty(s, k as CFString)?.takeRetainedValue() }
func fieldBase(_ t: Int64) -> Int32 { Int32(t << 16) }

struct Sensor {
    let service: AnyObject
    let name: String
    let usage: Int
    let eventType: Int64
}

// Discover once, including zero-valued sensors this time: presence of an event
// is the signal, not the magnitude.
var sensors: [Sensor] = []
for service in services {
    let name = (property(service, "Product") as? String) ?? "(unnamed)"
    let usage = (property(service, "PrimaryUsage") as? Int) ?? -1
    for type in Int64(0)...63 {
        guard let ref = copyEvent(service, type, 0, 0) else { continue }
        let value = getFloat(ref.takeRetainedValue(), fieldBase(type))
        guard value.isFinite else { continue }
        sensors.append(Sensor(service: service, name: name, usage: usage, eventType: type))
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "enumerate"

func read(_ s: Sensor) -> Double? {
    guard let ref = copyEvent(s.service, s.eventType, 0, 0) else { return nil }
    let v = getFloat(ref.takeRetainedValue(), fieldBase(s.eventType))
    return v.isFinite ? v : nil
}

if mode == "enumerate" {
    // Group by usage so non-temperature sensor families are visible even when
    // every one of them currently reads zero.
    var byUsage: [Int: [Sensor]] = [:]
    for s in sensors { byUsage[s.usage, default: []].append(s) }
    for (usage, group) in byUsage.sorted(by: { $0.key < $1.key }) {
        let types = Set(group.map(\.eventType)).sorted()
        print(String(format: "usage 0x%04x — %d sensors, event types %@",
                     usage, group.count, types.map(String.init).joined(separator: ",")))
        for s in group.sorted(by: { $0.name < $1.name }) {
            let v = read(s).map { String(format: "%.3f", $0) } ?? "nil"
            print("    \(s.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(v)")
        }
    }
    exit(0)
}

// watch mode: print the max and mean of the die-temperature sensors once a
// second. Max matters more than mean for a thermal reading, but a mean over 20+
// sensors is far harder to move by chance, so agreement between the two is
// itself corroboration.
let dies = sensors.filter { $0.usage == 0x0005 && $0.name.hasPrefix("PMU tdie") }
let seconds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 10 : 10
print("watching \(dies.count) die sensors for \(seconds)s")
for tick in 0..<seconds {
    let values = dies.compactMap(read)
    guard !values.isEmpty else { print("\(tick)s  no readings"); continue }
    let mean = values.reduce(0, +) / Double(values.count)
    print(String(format: "%3ds  max %6.2f  mean %6.2f  n=%d", tick, values.max()!, mean, values.count))
    Thread.sleep(forTimeInterval: 1)
}
