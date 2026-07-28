import MetricsEngine
import SwiftUI

/// Adapts an optional numeric field into something `Comparable`, purely so
/// `TableColumn(_:value:content:)` — which requires `V: Comparable` to
/// synthesize a `KeyPathComparator` for the header's sort indicator — can
/// bind to a column backed by an optional value. Most of `ProcessRow`'s
/// fields are optional (`Double?`, `UInt64?`, `Int?`), and `Optional` itself
/// does not conform to `Comparable`, so the brief's columns for CPU, Memory,
/// Threads, CPU Time, Disk Read and Disk Write do not compile without this.
///
/// The `<` below is never actually invoked to decide what the table shows:
/// `resort()` reads only `.keyPath` and `.order` off the bound comparator and
/// always sorts through `ProcessComparator`, which is where unknowns-last is
/// genuinely enforced. This type exists solely to satisfy the generic
/// constraint and give each optional column a distinct key path that
/// `ProcessesPage.field(for:)` can recognise.
struct ProcessSortKey<Value: Comparable>: Comparable {
    let value: Value?

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, nil): false
        case (nil, _): true
        case (_, nil): false
        case let (l?, r?): l < r
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}

extension ProcessRow {
    var cpuFractionKey: ProcessSortKey<Double> { ProcessSortKey(value: cpuFraction) }
    var memoryBytesKey: ProcessSortKey<UInt64> { ProcessSortKey(value: memoryBytes) }
    var threadCountKey: ProcessSortKey<Int> { ProcessSortKey(value: threadCount) }
    var cpuTimeSecondsKey: ProcessSortKey<Double> { ProcessSortKey(value: cpuTimeSeconds) }
    var diskReadBytesKey: ProcessSortKey<UInt64> { ProcessSortKey(value: diskReadBytes) }
    var diskWrittenBytesKey: ProcessSortKey<UInt64> { ProcessSortKey(value: diskWrittenBytes) }
}

/// The live process table.
///
/// Deliberately not built on `HardwarePage`: that container is shaped around a
/// primary value, a chart and a stats block, and a table has none of them.
public struct ProcessesPage: View {

    private let store: MetricsStore
    @State private var resolver = UserNameResolver()
    @State private var filter = ""

    /// Bound to the `Table` so headers show and drive their sort indicators.
    /// SwiftUI types this to whatever `TableColumn(_:value:)` produces —
    /// `KeyPathComparator` — so a custom comparator cannot go here. It is
    /// translated into a `ProcessComparator` in `resort()`, which is where the
    /// unknowns-last rule is actually applied.
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuFractionKey, order: .reverse)]

    /// Which columns are visible. Six show by default; the other four are
    /// available from the header's context menu.
    @State private var columns = TableColumnCustomization<ProcessRow>()

    /// PIDs in the order they are currently displayed. Recomputed only when the
    /// sort changes or the view appears — between those, values refresh in
    /// place so a row can be read without it moving underneath the pointer.
    @State private var displayOrder: [pid_t] = []

    public init(store: MetricsStore) {
        self.store = store
    }

    public var body: some View {
        // Computed ONCE per body evaluation and threaded down. These were
        // computed properties in an earlier draft, which meant every heat cell
        // re-filtered, re-ordered and re-scanned all ~600 rows — thousands of
        // passes per redraw.
        let rows = orderedRows()
        let cpuMaximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        let memoryMaximum = ProcessTable.maximum(
            of: { $0.memoryBytes.map(Double.init) }, in: rows
        )

        return VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
            header
            content(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
        }
        .padding(Vitals.Metrics.contentPadding)
        .task { await store.stream(.processes) }
        .onAppear(perform: resort)
        .onChange(of: sortOrder) { _, _ in resort() }
    }

    private func orderedRows() -> [ProcessRow] {
        guard let sample = store.processes else { return [] }
        let all = ProcessTable.rows(from: sample, resolver: resolver)
        return ProcessTable.ordered(ProcessTable.filtered(all, query: filter), keeping: displayOrder)
    }

    private var header: some View {
        HStack {
            Text("Processes").font(Vitals.Typography.sectionTitle)
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    @ViewBuilder
    private func content(
        rows: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?
    ) -> some View {
        if store.processes == nil {
            message("No process listing available.")
        } else if rows.isEmpty {
            // Distinct from having no data: this is a real listing that the
            // filter excluded everything from.
            message("No process matches \u{201C}\(filter)\u{201D}.")
        } else {
            table(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(Vitals.Typography.label).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func table(
        rows: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?
    ) -> some View {
        Table(rows, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Process", value: \.name) { row in
                Text(row.name).lineLimit(1)
            }
            .customizationID("name")

            TableColumn("CPU", value: \.cpuFractionKey) { row in
                heatCell(ProcessRow.formatCPU(row.cpuFraction),
                         heat: ProcessTable.heatFraction(row.cpuFraction, maximum: cpuMaximum))
            }
            .customizationID("cpu")

            TableColumn("Memory", value: \.memoryBytesKey) { row in
                heatCell(ProcessRow.formatMemory(row.memoryBytes),
                         heat: ProcessTable.heatFraction(row.memoryBytes.map(Double.init),
                                                         maximum: memoryMaximum))
            }
            .customizationID("memory")

            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)").monospacedDigit()
            }
            .customizationID("pid")

            TableColumn("User", value: \.userName) { row in
                Text(row.userName).lineLimit(1)
            }
            .customizationID("user")

            TableColumn("Threads", value: \.threadCountKey) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatCount(row.threadCount)))
                    .monospacedDigit()
            }
            .customizationID("threads")

            TableColumn("CPU Time", value: \.cpuTimeSecondsKey) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatCPUTime(row.cpuTimeSeconds)))
                    .monospacedDigit()
            }
            .customizationID("cpuTime")
            .defaultVisibility(.hidden)

            TableColumn("Disk Read", value: \.diskReadBytesKey) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatMemory(row.diskReadBytes)))
                    .monospacedDigit()
            }
            .customizationID("diskRead")
            .defaultVisibility(.hidden)

            TableColumn("Disk Write", value: \.diskWrittenBytesKey) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatMemory(row.diskWrittenBytes)))
                    .monospacedDigit()
            }
            .customizationID("diskWrite")
            .defaultVisibility(.hidden)

            TableColumn("Architecture", value: \.name) { row in
                Text(ProcessRow.formatArchitecture(row.architecture))
            }
            .customizationID("architecture")
            .defaultVisibility(.hidden)
        }
        .monospacedDigit()
    }

    /// A numeric cell with the heat-map background behind it. An unreadable
    /// value gets no background at all — absence is not a low value.
    private func heatCell(_ text: String?, heat: Double?) -> some View {
        Text(ProcessRow.displayValue(text))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Vitals.Palette.cpu.opacity((heat ?? 0) * 0.35))
            )
    }

    /// Freezes a new display order from the current sort, translating SwiftUI's
    /// `KeyPathComparator` into the comparator that keeps unknowns last.
    private func resort() {
        guard let sample = store.processes else { return }
        let all = ProcessTable.rows(from: sample, resolver: resolver)
        displayOrder = ProcessTable.filtered(all, query: filter)
            .sorted(using: processComparator())
            .map(\.pid)
    }

    /// Maps the bound `KeyPathComparator` back to a `ProcessSortField`.
    /// Defaults to CPU descending if a key path is ever unrecognised, rather
    /// than leaving the table in whatever order the sampler happened to return.
    private func processComparator() -> ProcessComparator {
        guard let active = sortOrder.first else {
            return ProcessComparator(field: .cpu, order: .reverse)
        }
        let field = Self.field(for: active.keyPath) ?? .cpu
        return ProcessComparator(field: field, order: active.order)
    }

    static func field(for keyPath: PartialKeyPath<ProcessRow>) -> ProcessSortField? {
        switch keyPath {
        case \ProcessRow.name: .name
        case \ProcessRow.cpuFractionKey: .cpu
        case \ProcessRow.memoryBytesKey: .memory
        case \ProcessRow.pid: .pid
        case \ProcessRow.userName: .user
        case \ProcessRow.threadCountKey: .threads
        case \ProcessRow.cpuTimeSecondsKey: .cpuTime
        case \ProcessRow.diskReadBytesKey: .diskRead
        case \ProcessRow.diskWrittenBytesKey: .diskWrite
        default: nil
        }
    }
}
