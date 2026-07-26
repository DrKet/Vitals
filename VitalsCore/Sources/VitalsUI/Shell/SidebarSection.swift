import Foundation

/// The twelve sections of the main window, in sidebar order.
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, processes
    case cpu, memory, gpu, storage, network, sensors
    case startup, services, users, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .processes: "Processes"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .storage: "Storage"
        case .network: "Network"
        case .sensors: "Sensors"
        case .startup: "Startup"
        case .services: "Services"
        case .users: "Users"
        case .history: "History"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .processes: "list.bullet.rectangle"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.transparent"
        case .storage: "internaldrive"
        case .network: "network"
        case .sensors: "thermometer.medium"
        case .startup: "arrow.up.forward.app"
        case .services: "gearshape.2"
        case .users: "person.2"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Whether this plan builds the section. Sections that are not yet built say
    /// so plainly rather than showing an empty pane.
    public var isImplemented: Bool {
        switch self {
        case .overview, .cpu, .memory, .gpu: true
        default: false
        }
    }

    public struct Group: Identifiable, Sendable {
        public let name: String
        public let sections: [SidebarSection]
        public var id: String { name }
    }

    public static var groups: [Group] {
        [
            Group(name: "Monitor", sections: [.overview, .processes]),
            Group(name: "Hardware", sections: [.cpu, .memory, .gpu, .storage, .network, .sensors]),
            Group(name: "System", sections: [.startup, .services, .users, .history]),
        ]
    }
}
