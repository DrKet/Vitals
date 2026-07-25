import Testing
@testable import VitalsUI

@Suite("Sidebar sections")
struct SidebarSectionTests {

    @Test("all twelve spec'd sections are present")
    func allSectionsPresent() {
        #expect(SidebarSection.allCases.count == 12)
    }

    @Test("sections are grouped as Monitor, Hardware, System")
    func sectionsAreGrouped() {
        let groups = SidebarSection.groups.map(\.name)
        #expect(groups == ["Monitor", "Hardware", "System"])
    }

    @Test("every section belongs to exactly one group")
    func everySectionIsGroupedOnce() {
        let grouped = SidebarSection.groups.flatMap(\.sections)
        #expect(grouped.count == SidebarSection.allCases.count)
        #expect(Set(grouped) == Set(SidebarSection.allCases))
    }

    @Test("overview and CPU are implemented in this plan; the rest are not yet")
    func implementedSectionsAreMarked() {
        #expect(SidebarSection.overview.isImplemented)
        #expect(SidebarSection.cpu.isImplemented)
        #expect(SidebarSection.processes.isImplemented == false)
        #expect(SidebarSection.sensors.isImplemented == false)
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
