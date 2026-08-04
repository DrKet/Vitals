import SwiftUI

public struct AppShell: View {
    @State private var selection: SidebarSection = .overview
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.groups(hasBattery: store.profile?.hasBattery == true)) { group in
                    Section(group.name) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol)
                                .tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Vitals.Metrics.contentPadding)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewPage(store: store)
        case .processes:
            ProcessesPage(store: store)
        case .cpu:
            CPUPage(store: store)
        case .memory:
            MemoryPage(store: store)
        case .gpu:
            GPUPage(store: store)
        case .storage:
            StoragePage(store: store)
        case .network:
            NetworkPage(store: store)
        case .sensors:
            SensorsPage(store: store)
        default:
            NotYetBuilt(section: selection)
        }
    }
}

/// Says plainly that a section is not built yet, rather than showing an empty
/// pane the user has to interpret.
struct NotYetBuilt: View {
    let section: SidebarSection

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(Vitals.Typography.sectionTitle)
            Text("Not built yet.")
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
