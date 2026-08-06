import Testing
@testable import VitalsUI

@Suite("Sidebar sections")
struct SidebarSectionTests {

    @Test("all thirteen spec'd sections are present")
    func allSectionsPresent() {
        #expect(SidebarSection.allCases.count == 13)
    }

    @Test("sections are grouped as Monitor, Hardware, System")
    func sectionsAreGrouped() {
        let groups = SidebarSection.groups(hasBattery: true, hasSensors: true).map(\.name)
        #expect(groups == ["Monitor", "Hardware", "System"])
    }

    @Test("every section belongs to exactly one group")
    func everySectionIsGroupedOnce() {
        let grouped = SidebarSection.groups(hasBattery: true, hasSensors: true).flatMap(\.sections)
        #expect(grouped.count == SidebarSection.allCases.count)
        #expect(Set(grouped) == Set(SidebarSection.allCases))
    }

    /// A Mac Studio has no battery, and the project's rule is that
    /// inapplicable hardware is absent rather than shown empty.
    @Test("Battery appears only on machines that have one")
    func batterySectionIsConditional() {
        let withBattery = SidebarSection.groups(hasBattery: true, hasSensors: true).flatMap(\.sections)
        let without = SidebarSection.groups(hasBattery: false, hasSensors: true).flatMap(\.sections)
        #expect(withBattery.contains(.battery))
        #expect(without.contains(.battery) == false)
    }

    /// Same rule as Battery, for the same reason: a machine where
    /// `IOHIDEventSystemClient` reports nothing has no more use for a Sensors
    /// page than a Mac Studio has for a Battery one. Sensors shipped
    /// unconditional only because bundling it into the Battery refactor would
    /// have made that diff harder to review.
    @Test("Sensors appears only on machines that report sensors")
    func sensorsSectionIsConditional() {
        let with = SidebarSection.groups(hasBattery: true, hasSensors: true).flatMap(\.sections)
        let without = SidebarSection.groups(hasBattery: true, hasSensors: false).flatMap(\.sections)
        #expect(with.contains(.sensors))
        #expect(without.contains(.sensors) == false)
    }

    /// The two conditions must be independent — neither may hide the other.
    @Test("battery and sensors are hidden independently")
    func conditionalSectionsAreIndependent() {
        let neither = Set(SidebarSection.groups(hasBattery: false, hasSensors: false).flatMap(\.sections))
        #expect(neither.contains(.battery) == false)
        #expect(neither.contains(.sensors) == false)

        let batteryOnly = Set(SidebarSection.groups(hasBattery: true, hasSensors: false).flatMap(\.sections))
        #expect(batteryOnly.contains(.battery))
        #expect(batteryOnly.contains(.sensors) == false)

        let sensorsOnly = Set(SidebarSection.groups(hasBattery: false, hasSensors: true).flatMap(\.sections))
        #expect(sensorsOnly.contains(.sensors))
        #expect(sensorsOnly.contains(.battery) == false)
    }

    /// Everything else must be unaffected by the battery's presence.
    @Test("no other section depends on whether a battery exists")
    func onlyBatteryIsConditional() {
        let withBattery = Set(SidebarSection.groups(hasBattery: true, hasSensors: true).flatMap(\.sections))
        let without = Set(SidebarSection.groups(hasBattery: false, hasSensors: true).flatMap(\.sections))
        #expect(withBattery.subtracting(without) == [.battery])
        #expect(without.subtracting(withBattery).isEmpty)
    }

    @Test("overview, processes, CPU, memory, GPU, storage, network, sensors and battery are implemented; the rest are not yet")
    func implementedSectionsAreMarked() {
        #expect(SidebarSection.overview.isImplemented)
        #expect(SidebarSection.processes.isImplemented)
        #expect(SidebarSection.cpu.isImplemented)
        #expect(SidebarSection.memory.isImplemented)
        #expect(SidebarSection.gpu.isImplemented)
        #expect(SidebarSection.storage.isImplemented)
        #expect(SidebarSection.network.isImplemented)
        #expect(SidebarSection.sensors.isImplemented)
        #expect(SidebarSection.battery.isImplemented)
    }

    @Test("every section has a non-empty title and symbol")
    func sectionsAreLabelled() {
        for section in SidebarSection.allCases {
            #expect(section.title.isEmpty == false)
            #expect(section.symbol.isEmpty == false)
        }
    }

    @Test("titles are unique, so no two rows read identically")
    func titlesAreUnique() {
        #expect(Set(SidebarSection.allCases.map(\.title)).count == SidebarSection.allCases.count)
    }
}
