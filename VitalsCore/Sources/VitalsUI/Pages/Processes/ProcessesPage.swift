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

    /// Deliberately traps rather than implementing nil-first ordering.
    ///
    /// This type's whole reason to exist is that its `<` is a promise nothing
    /// keeps: `SwiftUI.Table` only ever reads `.keyPath`/`.order` off the bound
    /// `KeyPathComparator` (see `resort()`), never calls `sorted(using:)` on it
    /// directly. A correct-looking `<` that returned `true` for `(nil, _)`
    /// would sort unreadable processes FIRST ascending — exactly the bug this
    /// milestone exists to prevent — and nothing would notice, because nothing
    /// exercises it today. `rows.sorted(using: sortOrder)` is also the most
    /// idiomatic line in every SwiftUI `Table` tutorial, so it is exactly what
    /// a future maintainer would reach for. Trapping turns "silently wrong
    /// order in production" into "crashes immediately, naming why," the first
    /// time anyone actually calls it — enforcing the invariant instead of
    /// merely documenting it.
    static func < (lhs: Self, rhs: Self) -> Bool {
        preconditionFailure("""
            ProcessSortKey.< must never be called. SwiftUI's Table reads only \
            .keyPath and .order off the bound KeyPathComparator (see \
            ProcessesPage.resort()); actual ordering always goes through \
            ProcessComparator, which is where unreadable values are kept last \
            in both directions. If this fired, something started calling \
            sorted(using:) on the raw KeyPathComparator directly, bypassing \
            that rule.
            """)
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

    /// A dedicated, plain-`String` binding for the Architecture column.
    ///
    /// `String` is already `Comparable`, so — unlike the fields above — this
    /// needs no `ProcessSortKey` wrapper: architecture is never absent, and
    /// there is no meaningful order between native and translated beyond the
    /// words `ProcessComparator.architecture` already sorts by, so wrapping it
    /// as `Comparable` conformance on `ProcessArchitecture` itself would be
    /// manufacturing an ordering nobody asked for. Distinct from `\.name` so
    /// `TableColumn("Architecture", value:)` no longer shares a key path with
    /// the Process column — sharing one made both columns' sort indicators
    /// indistinguishable and meant clicking "Architecture" silently sorted by
    /// name.
    var architectureKey: String { ProcessRow.formatArchitecture(architecture) }
}

/// The live process table.
///
/// Deliberately not built on `HardwarePage`: that container is shaped around a
/// primary value, a chart and a stats block, and a table has none of them.
public struct ProcessesPage: View {

    private let store: MetricsStore
    @State private var resolver = UserNameResolver()
    @State private var filter: String

    /// Bound to the `Table` so headers show and drive their sort indicators.
    /// SwiftUI types this to whatever `TableColumn(_:value:)` produces —
    /// `KeyPathComparator` — so a custom comparator cannot go here. It is
    /// translated into a `ProcessComparator` in `resort()`, which is where the
    /// unknowns-last rule is actually applied.
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuFractionKey, order: .reverse)]

    /// Which columns are visible. Six show by default; the other four are
    /// available from the header's context menu.
    @State private var columns = TableColumnCustomization<ProcessRow>()

    /// PIDs in the order they are currently displayed. Recomputed whenever the
    /// sort changes, the filter changes, the view appears, or a listing first
    /// arrives — between those, values refresh in place so a row can be read
    /// without it moving underneath the pointer.
    ///
    /// Starts empty, which `ProcessTable.ordered(_:keeping:)` treats as "no
    /// order established yet" and passes its input through unchanged — i.e.
    /// sampler order. That is only ever what's on screen for the fraction of a
    /// frame between a listing landing and the `onChange` below reacting to it
    /// (see `body`'s doc comment), never a state a user can see settle.
    @State private var displayOrder: [pid_t] = []

    /// Whether the page has locked in its one-time default ordering from a
    /// sample that could actually differentiate processes by CPU. See the
    /// `onChange(of: store.processes?.cpuUsage.isEmpty)` handler in `body`
    /// for why "the first sample to arrive" and "the first sample worth
    /// sorting by" are not the same tick.
    @State private var establishedDefaultOrder = false

    /// The selected process, held by identity (pid + start time) so a recycled
    /// pid never transfers the selection — see `ProcessTable.validSelection`.
    /// The `Table` below is driven by a computed `Binding<pid_t?>`, not this
    /// directly, so the guard is applied on every read.
    @State private var selected: ProcessIdentity?

    public init(store: MetricsStore) {
        self.init(store: store, initialFilter: "")
    }

    /// Seeds the filter at construction rather than leaving it at `""`.
    ///
    /// Not `public`: application code has no reason to pre-seed a filter —
    /// this exists purely so `ProcessesPageTests` can exercise the Filtering
    /// section (visible rows narrowing, heat rescaling to what remains) at
    /// the page level. The filter field is private `@State` driven by a
    /// `TextField`, which the offscreen `NSHostingView` harness this suite
    /// uses has no way to type into; seeding it here is the one legitimate
    /// way in short of adding UI automation this project has no other need
    /// for.
    init(store: MetricsStore, initialFilter: String) {
        self.store = store
        self._filter = State(initialValue: initialFilter)
    }

    public var body: some View {
        // `all`/`filtered` computed ONCE per body evaluation and threaded down
        // to both rendering and `resort`. These were computed properties in an
        // earlier draft, which meant every heat cell re-filtered, re-ordered
        // and re-scanned all ~600 rows — thousands of passes per redraw. The
        // sharing is also what stops each `onChange`/`onAppear` below from
        // doing its own redundant `ProcessTable.rows(from:resolver:)` pass:
        // `resort` here closes over `filtered` rather than rebuilding it, so a
        // header click walks the ~600 rows once (for this render), not twice.
        let all = currentRows()
        let filtered = ProcessTable.filtered(all, query: filter)
        let rows = ProcessTable.ordered(filtered, keeping: displayOrder)
        let cpuMaximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        let memoryMaximum = ProcessTable.maximum(
            of: { $0.memoryBytes.map(Double.init) }, in: rows
        )

        // Reported selection is guarded on every read: the getter returns a
        // pid only when a current row matches the stored identity, and the
        // setter records the full identity of the clicked row. Built over
        // `all` (unfiltered) so a selection the filter hides survives and
        // reappears when the filter clears; `Table` renders `rows`, and a pid
        // absent from the visible set simply shows no selection meanwhile.
        let selection = Binding<pid_t?>(
            get: { ProcessTable.validSelection(selected, in: all)?.pid },
            set: { newValue in
                selected = newValue.flatMap { pid in all.first { $0.pid == pid }?.identity }
            }
        )

        return VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
            header
            if Self.showsMeasuringNotice(for: store.processes) {
                Text("Measuring — CPU and disk rates need a second sample.")
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
            }
            content(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum, selection: selection)
        }
        .padding(Vitals.Metrics.contentPadding)
        .task { await store.stream(.processes) }
        .onAppear {
            resort(filtered: filtered)
            markDefaultOrderEstablishedIfMeaningful()
        }
        .onChange(of: sortOrder) { _, _ in resort(filtered: filtered) }
        // Narrowing the filter is harmless on its own — a subset preserves
        // `displayOrder`'s existing relative order. Clearing it is not: rows
        // the old filter hid are absent from `displayOrder`, so `ordered`
        // would append them below in raw sampler order, leaving a visibly
        // unsorted tail. Resorting on every filter change (not just when it
        // widens) is what keeps that tail from ever appearing.
        .onChange(of: filter) { _, _ in resort(filtered: filtered) }
        // The default sort's whole point: on a cold page `store.processes`
        // starts nil, so `displayOrder` starts empty and `ordered` passes
        // sampler order straight through. Nothing previously re-ran `resort`
        // when the first listing landed, so the very first thing a user saw
        // was raw sampler order, not CPU-descending — the one moment this
        // milestone is about.
        //
        // Keyed on `cpuUsage.isEmpty` rather than plain nil-ness, and gated by
        // `establishedDefaultOrder` rather than firing exactly once, for a
        // reason discovered only by running the real app against a live
        // engine: `ProcessCPUTracker.update(_:at:)` computes a process' CPU
        // fraction as a delta against the PREVIOUS sample, so the very FIRST
        // `ProcessSeriesSample` a cold engine ever delivers has an entirely
        // EMPTY `cpuUsage` — every process is unreadable on tick one, not
        // because anything is broken, but because there is nothing yet to
        // diff against. Locking `displayOrder` in from that tick "sorts"
        // a column where everything ties, which is a stable no-op
        // indistinguishable from sampler order — exactly the bug this fix
        // exists to close, just one tick later than the naive nil-check
        // catches. Re-triggering on each `cpuUsage.isEmpty` transition (nil
        // -> true -> false) and only setting `establishedDefaultOrder` once a
        // tick actually has readable CPU data means the frozen order always
        // comes from the first sample capable of showing one, while still
        // never touching `displayOrder` again afterward — preserving "order
        // holds" for every tick after that. (Not keyed on the sample itself:
        // `ProcessSeriesSample` isn't `Equatable`, and it changes on every
        // live tick regardless — resorting every tick would fight that same
        // "order holds" contract this is careful not to break.)
        .onChange(of: store.processes?.cpuUsage.isEmpty) { _, _ in
            guard !establishedDefaultOrder else { return }
            resort(filtered: filtered)
            markDefaultOrderEstablishedIfMeaningful()
        }
    }

    /// Locks in `establishedDefaultOrder` once — and only once — `resort()`
    /// has run against a sample that could actually tell processes apart by
    /// CPU. Shared by `onAppear` (the pre-populated-fixture / already-warm
    /// path, where the first sample this page ever sees may already be a
    /// real one) and the `cpuUsage.isEmpty` handler above (the cold-launch
    /// path, where it usually is not).
    private func markDefaultOrderEstablishedIfMeaningful() {
        guard let sample = store.processes, !sample.cpuUsage.isEmpty else { return }
        establishedDefaultOrder = true
    }

    private func currentRows() -> [ProcessRow] {
        guard let sample = store.processes else { return [] }
        return ProcessTable.rows(from: sample, resolver: resolver)
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
        rows: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?,
        selection: Binding<pid_t?>
    ) -> some View {
        if store.processes == nil {
            message("No process listing available.")
        } else if rows.isEmpty && !filter.isEmpty {
            // Distinct from having no data: this is a real listing that the
            // filter excluded everything from. Keyed on the filter also being
            // non-empty so a listing that is itself genuinely empty (nothing
            // to filter away) never renders `No process matches ""` — nonsense
            // that blames a filter which was never applied.
            message("No process matches \u{201C}\(filter)\u{201D}.")
        } else {
            table(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum, selection: selection)
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
        rows: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?,
        selection: Binding<pid_t?>
    ) -> some View {
        Table(rows, selection: selection, sortOrder: $sortOrder, columnCustomization: $columns) {
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
                                                         maximum: memoryMaximum),
                         tint: Vitals.Palette.memory)
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

            TableColumn("Architecture", value: \.architectureKey) { row in
                Text(ProcessRow.formatArchitecture(row.architecture))
            }
            .customizationID("architecture")
            .defaultVisibility(.hidden)
        }
        .monospacedDigit()
    }

    /// A numeric cell with the heat-map background behind it. An unreadable
    /// value gets no background at all — absence is not a low value.
    ///
    /// `tint` defaults to CPU's accent so every existing call site (before
    /// this had a Memory-specific one to pass) keeps its prior colour, but
    /// each column now passes its own subsystem hue — see `Vitals.Palette` —
    /// rather than every heat cell on the page reading CPU-blue regardless of
    /// which column it is in.
    private func heatCell(_ text: String?, heat: Double?, tint: Color = Vitals.Palette.cpu) -> some View {
        Text(ProcessRow.displayValue(text))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity((heat ?? 0) * 0.35))
            )
    }

    /// Freezes a new display order from the current sort, translating SwiftUI's
    /// `KeyPathComparator` into the comparator that keeps unknowns last.
    ///
    /// Takes the already filtered rows rather than rebuilding them from
    /// `store.processes` — `body` builds `filtered` once per render and every
    /// caller here (`onAppear`, and the three `onChange`s above) closes over
    /// that same value, so this never repeats the ~600-row
    /// `ProcessTable.rows(from:resolver:)` pass `body` already paid for.
    private func resort(filtered: [ProcessRow]) {
        displayOrder = filtered
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

    /// Whether to explain the column of em dashes a cold page shows.
    ///
    /// True only in the window between the first listing arriving and the
    /// first CPU rates being computable — `ProcessCPUTracker` needs two
    /// samples, so for roughly 5-10 seconds every rate is genuinely
    /// unmeasured. The dashes are correct and stay; this only says why.
    ///
    /// Keyed on the same `cpuUsage.isEmpty` condition the `onChange` handler
    /// in `body` already watches to re-sort, rather than a second notion of
    /// "cold" that could drift from it. A nil sample is excluded because that
    /// state has its own "No process listing available." message, and showing
    /// both would claim to be measuring something that was never listed.
    static func showsMeasuringNotice(for sample: ProcessSeriesSample?) -> Bool {
        guard let sample else { return false }
        return sample.cpuUsage.isEmpty
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
        case \ProcessRow.architectureKey: .architecture
        default: nil
        }
    }
}
