# Vitals — Design Specification

**Date:** 2026-07-24
**Status:** Approved for planning
**Platform:** macOS 26.0+, Swift 6, SwiftUI

---

## 1. Summary

Vitals is a macOS system monitor that combines the information density of Windows Task
Manager with the visual language of Apple's first-party apps. It has three surfaces: a main
window for investigation, live desktop widgets for ambient monitoring, and a menu bar readout
for glanceable status.

The design resolves one central tension. "Clean and minimalist" and "everything Windows Task
Manager shows" pull in opposite directions. Vitals resolves it through progressive disclosure:
each page shows the few numbers you actually watch, with the complete specification one click
away and sticky once opened.

### Non-goals

- Mac App Store distribution. Sandboxing would forbid full process enumeration, process
  control, and sensor access. This is a locally built, ad-hoc signed app.
- Support for macOS 25 and earlier. Targeting 26 exclusively means Liquid Glass is a native
  API and no fallback material code is written.
- Benchmarking, stress testing, or historical analytics beyond per-app rollups.

---

## 2. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Widget technology | Custom floating `NSPanel`s | WidgetKit's timeline budget makes per-second live graphs impossible |
| Distribution | Local dev build, ad-hoc signed | No entitlement constraints on process control or sensor access |
| Privileges | Opt-in privileged helper | Full function unprivileged; helper unlocks gated metrics |
| Main window navigation | Glass sidebar | Only pattern that scales to twelve sections; matches Finder and System Settings |
| Detail density | Progressive disclosure | Delivers Task Manager parity without paying for it visually |
| Graph style | Stacked gradient area, histogram as alternate mode | One engine, two render modes |
| Widget appearance | Liquid Glass cards on Apple's widget geometry | Legible on any wallpaper; sits naturally beside first-party widgets |
| Menu bar | Live configurable readouts | The primary daily interaction; the window is for investigation |

---

## 3. Architecture

Swift packages in one Xcode workspace. Each module is independently testable and small enough
to reason about in isolation.

| Module | Responsibility | Depends on |
|---|---|---|
| `SystemMetrics` | Pure sampling, one file per domain. No UI, no state. | Foundation, IOKit, Metal |
| `MetricsEngine` | Actor. Schedules samplers, owns ring buffers, publishes `AsyncStream`s. | `SystemMetrics` |
| `HistoryStore` | SQLite persistence for long-term per-app rollups. | — |
| `VitalsUI` | Design system: glass surfaces, chart primitives, typography, colour ramps. | — |
| `VitalsApp` | Main window and all its pages. | all |
| `WidgetCanvas` | Floating panel system and composable widget builder. | `MetricsEngine`, `VitalsUI` |
| `MenuBarExtra` | Status item and dropdown panel. | `MetricsEngine`, `VitalsUI` |
| `VitalsHelper` | Privileged XPC daemon. Minimal surface, independently auditable. | — |

### Governing principles

**Subscription-driven sampling.** No metric is sampled unless something displays it. A desktop
showing only CPU widgets never enumerates the process table. Target overhead is under 1% CPU at
1 Hz. A system monitor that appears in its own top-offenders list has failed.

**Never fabricate a number.** Where a value is derived rather than measured, it is labelled as
derived. Where a value is unavailable on this hardware, the UI says so rather than showing zero.
This rule has teeth — see the Apple Silicon memory case in §4.2.

**Independent failure.** Every sampler returns a `Result`. A failing sampler degrades to an
`unavailable` state carrying a reason. One broken sensor never blanks a page or crashes the app.

**Capability detection drives UI.** A `HardwareProfile` is built at launch. Pages and fields that
do not apply to the current machine are absent, not empty: no fan gauge on a fanless laptop, no
dedicated-VRAM field on a unified-memory system, no DIMM slot table on Apple Silicon.

---

## 4. Data sources

All APIs below were verified as functional on the development machine (M2 Pro, macOS 26.2)
before being written into this spec.

### 4.1 CPU

| Datum | Source |
|---|---|
| Per-core utilisation | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, tick deltas |
| Topology, P/E clusters | `sysctl hw.perflevel0/1.*` |
| Cache sizes | `sysctl hw.l1dcachesize`, `hw.l2cachesize`, `hw.l3cachesize` |
| Per-cluster frequency | IOReport DVFS state residency, weighted against the frequency table in IORegistry `voltage-states` |
| Package / core power | IOReport Energy Model channel |
| Load average, uptime | `sysctl vm.loadavg`, `kern.boottime` |
| Process, thread, port counts | `KERN_PROC_ALL`, `task_info` |

### 4.2 Memory

| Datum | Source |
|---|---|
| Active, inactive, wired, compressed, free | `host_statistics64(HOST_VM_INFO64)` |
| Swap usage | `sysctl vm.swapusage` |
| Memory pressure | `kern.memorystatus_vm_pressure_level` |
| Unified memory detection | `MTLDevice.hasUnifiedMemory` |
| Type, manufacturer | `SPMemoryDataType` |
| DIMM slots, speed in MHz, form factor | `SPMemoryDataType` — **Intel only** |

**The Apple Silicon memory-speed case.** Apple Silicon exposes no memory clock. A probe on the
development machine returns type (`LPDDR5`) and manufacturer (`SK Hynix`) and nothing more.
Vitals therefore does not display a MHz figure on Apple Silicon. It displays:

> **16 GB LPDDR5 · Unified · SK Hynix**
> 200 GB/s peak bandwidth *(SoC specification)*

The bandwidth comes from a static SoC lookup table and is explicitly labelled as a specification
figure, not a measurement. On Intel Macs the same panel shows real per-slot DIMM speeds, because
there they genuinely exist. Inventing a plausible-looking Apple Silicon memory clock is
prohibited by §3.

### 4.3 GPU

| Datum | Source |
|---|---|
| Device, renderer, tiler utilisation % | `IOAccelerator` → `PerformanceStatistics` |
| In-use and allocated system memory | `IOAccelerator` → `PerformanceStatistics` |
| Device name, core count | `MTLDevice` |
| Recommended working set | `MTLDevice.recommendedMaxWorkingSetSize` |
| Dedicated VRAM (discrete) | `IOPCIDevice` properties |
| Per-process GPU usage | `powermetrics` via helper — **gated** |

Three memory topologies are modelled distinctly and the UI adapts to which one is present:

- **Unified** (Apple Silicon) — one pool. GPU allocation is shown as a share of system memory.
- **Dedicated** (discrete GPU) — separate VRAM, reported with its own capacity and utilisation.
- **Shared** (Intel integrated) — carved from system RAM. Both current shared usage and the
  maximum shared allocation are reported.

Multiple GPUs, including eGPUs, are enumerated and shown separately.

### 4.4 Storage

| Datum | Source |
|---|---|
| Volume capacity and free space | `URLResourceValues`, APFS-container aware to avoid double-counting |
| Device model, bus protocol | `IOBlockStorageDevice` |
| SSD vs HDD | `IOBlockStorageDevice` rotational-media property |
| TRIM support | `IONVMeController` / `SPNVMeDataType` |
| Throughput, IOPS, latency, active time | `IOBlockStorageDriver` → `Statistics` |
| SMART health, wear, TBW, power-on hours | `IONVMeSMARTUserClient` via helper — **gated** |

### 4.5 Network

Per-interface counters from `NET_RT_IFLIST2`. Addresses via `getifaddrs`. Wi-Fi detail — SSID,
RSSI, PHY mode, negotiated rate, channel — via CoreWLAN. Per-process network attribution for
processes not owned by the current user is gated behind the helper.

### 4.6 Sensors

Apple Silicon temperatures via `IOHIDEventSystemClient` matching AppleSMC sensor services, which
works unprivileged. Intel temperatures and fan speeds via AppleSMC keys. Component power — CPU,
GPU, ANE, DRAM — from the IOReport Energy Model channel.

### 4.7 Processes

Enumeration via `KERN_PROC_ALL`. Per-process detail from `proc_pidinfo(PROC_PIDTASKINFO)` and
`proc_pid_rusage(RUSAGE_INFO_V6)`, which supplies disk I/O, energy impact, and cycle counts.

Memory is reported as **`phys_footprint`**, matching Activity Monitor's Memory column. RSS is
not used: it materially overstates memory on macOS and would make Vitals disagree with every
other tool on the system.

Applications are distinguished from background processes via `NSWorkspace.runningApplications`
and bundle inspection. Parent PIDs build the process tree.

---

## 5. Sampling engine

A single `MetricsEngine` actor owns scheduling. Samplers conform to:

```swift
protocol MetricSampler: Sendable {
    associatedtype Sample: Sendable
    var isAvailable: Bool { get }
    func sample() async throws -> Sample
}
```

Three cadence tiers, all user-configurable:

| Tier | Default | Contents |
|---|---|---|
| Fast | 1 Hz (0.5–5 s) | CPU, memory, GPU, network, disk throughput |
| Slow | 5 s | Process table, sensors |
| Static | 60 s | Volume capacities, hardware inventory |

Each series holds a 600-sample in-memory ring buffer — ten minutes at 1 Hz. Downsampled
aggregates are written to `HistoryStore` for App History.

Consumers subscribe via `AsyncStream`. The engine reference-counts subscriptions per series and
stops sampling any series with no subscribers. This is the mechanism that enforces the
subscription-driven principle in §3.

**Delta arithmetic** is the historical failure point in tools of this kind and is handled
explicitly: the first sample after subscription produces no rate and is discarded rather than
reported as a spike; counter wraparound is detected and the interval dropped; core count or
interface set changes invalidate the previous sample rather than producing a nonsense delta.

---

## 6. Main window

Glass sidebar with three groups:

- **Monitor** — Overview, Processes
- **Hardware** — CPU, Memory, GPU, Storage, Network, Sensors
- **System** — Startup, Services, Users, History

### 6.1 Overview

A responsive tile grid that fills the window. Tiles reflow and grow into available height as the
window resizes — more tiles per row and taller graphs, never a block of content stranded at the
top with dead space below it. Leftover vertical space goes to graph history, because empty space
in a monitoring app is wasted signal.

### 6.2 Hardware pages

Every hardware page follows one template:

1. Title with the hardware name and its vendor mark (Apple logo from the system font glyph;
   Intel wordmark as a bundled asset).
2. Primary value, large.
3. Primary graph.
4. A secondary visualisation where the hardware warrants one — the per-core grid on CPU, the
   volume bar on Storage.
5. Four key statistics.
6. A **Full specifications** disclosure containing everything else. Sticky once opened.

The CPU page's disclosure carries: per-cluster frequencies, cache sizes at each level, process
and thread and Mach port counts, uptime, load average, architecture, die temperature, package
power, and throttle state.

### 6.3 Charts

One `MetricChart` view with two render modes.

**Area mode** (default) — Catmull-Rom smoothed spline, vertical gradient fading to transparent
at the baseline, soft bloom on the stroke, a live dot at the leading edge, and gridlines at 25 /
50 / 75%. Supports stacked series, which is enabled by default wherever the metric has a natural
decomposition:

| Page | Stacked series |
|---|---|
| CPU | Performance cores / Efficiency cores |
| Memory | Wired / App / Compressed / Cached |
| GPU | Renderer / Tiler |
| Network | Down / Up |
| Disk | Read / Write |

Series order is load-bearing: the first series is the base band, is painted frontmost,
and is the one the live dot marks. Memory uses **App** (not Active) because that is the
field `MemorySample` exposes and what Activity Monitor labels "App Memory". Network leads
with **Down** (not Up) because inbound throughput is the figure people actually watch.

Stacking collapses to a single series on request.

**Histogram mode** — discrete rounded bars, one per sample, colour-ramped from blue to amber as
load climbs. Selectable on any chart, and the default at small widget sizes where bars read
better than a hairline curve.

Both modes support scrubbing: hovering freezes a crosshair and reads the exact value with its
timestamp.

### 6.4 Processes

Grouped into Apps / Background / System, with a toggle to a flat Details view and a toggle to a
process tree.

Columns: name, PID, user, status, CPU %, CPU time, memory footprint, compressed memory, threads,
ports, disk read/write, network up/down, GPU %, energy impact, sandbox status, and
**architecture** — showing which processes run natively and which run translated under Rosetta.

Windows Task Manager's heat-map cell shading is carried over: cell background intensity scales
with the value relative to other rows.

Context menu: Quit, Force Quit, Suspend, Resume, change priority via `renice`, Sample Process,
Spindump, Reveal in Finder, Copy PID, and Inspect.

The inspector sheet shows open files and ports, threads with their individual CPU time, full
executable path, code signature and team identifier, launch arguments, and environment.

### 6.5 System pages

**Startup** — login items via `SMAppService`, plus `LaunchAgents` and `LaunchDaemons` across all
five standard directories. Each entry can be enabled or disabled, with an impact rating computed
from Vitals' own recorded history rather than guessed at. This information is scattered across
System Settings and hidden plists today, which makes this page one of the more useful things in
the app.

**Services** — launchd job list with label, state, PID, last exit status, and start/stop control.

**Users** — sessions from `utmpx` with per-UID aggregated CPU and memory.

**History** — per-bundle cumulative CPU time, energy, network, and disk over 1/7/30 days, from
`HistoryStore`. macOS provides no equivalent of Windows' App History, so Vitals samples and
persists it.

---

## 7. Desktop widgets

### 7.1 Window behaviour

Each widget is a borderless `NSPanel` at desktop-icon window level, with `collectionBehavior` of
`[.canJoinAllSpaces, .stationary, .ignoresCycle]` so widgets follow across Spaces and stay out of
Mission Control cycling.

**Click-through by default.** At rest, widgets set `ignoresMouseEvents` — clicking one hits the
desktop behind it, exactly as Apple's widgets do. An **Edit Widgets** mode, entered from the menu
bar, makes widgets interactive for dragging, resizing, and configuration, then returns input to
the desktop on exit. Edit mode shows alignment guides and snapping to screen edges, to other
widgets, and to the widget grid.

**Layout persists per display**, keyed by display UUID, so disconnecting and reconnecting an
external monitor restores that screen's widgets rather than collapsing everything onto the
built-in display.

### 7.2 Appearance

Liquid Glass cards using Apple's widget geometry: the four standard footprints (small 2×2,
medium 4×2, large 4×4, extra-large 8×4), the system widget corner radius, and WidgetKit's content
margins. A Vitals widget beside a Calendar widget should read as the same species.

macOS desaturates desktop widgets when an app takes focus. Vitals mirrors this, with an opt-out
for users who want values always vivid.

### 7.3 The builder

Three steps, then styling:

1. **Source** — any core, any cluster, total CPU, any memory series, any GPU, any volume, any
   network interface, any temperature or power sensor.
2. **Visualisation** — stacked area graph, histogram, ring, bar, numeric readout, per-core grid,
   or sparkline.
3. **Size** — one of the four Apple footprints.
4. **Style** — glass intensity, tint, corner radius, opacity, label visibility, refresh rate.

Widget definitions are `Codable` JSON stored in Application Support, which makes them shareable
as files. There is no limit on widget count; each subscribes only to the series it displays.

---

## 8. Menu bar

An `NSStatusItem` hosting a SwiftUI view with a configurable readout set — any combination of CPU,
memory, GPU, network, temperature, and power.

The dropdown is a glass panel with mini-graphs for each major subsystem and the top five
processes by CPU, memory, and energy, each quittable in place. It also holds the Edit Widgets
toggle and app settings.

Sampling throttles when the dropdown is closed and pauses entirely when the menu bar is hidden
in fullscreen.

---

## 9. Privileged helper

A `SMJobBless` launch daemon, installed on demand from a settings toggle with a single
authorisation prompt. It is deliberately small and does exactly four things:

1. Read NVMe SMART attributes.
2. Run `powermetrics` with plist output and return parsed per-process GPU and power data.
3. Return per-process network attribution for processes owned by other users.
4. Signal, renice, and load/unload launchd jobs on request.

The XPC interface is a fixed, enumerated command set. It accepts no arbitrary paths and executes
no arbitrary commands. Client connections are validated by code signature.

The app is fully functional without it. Gated panels show an "Enable advanced metrics" affordance
rather than blank space or zeroes, and the helper can be removed at any time.

---

## 10. Milestones

| Milestone | Scope | Outcome |
|---|---|---|
| **M1** | `SystemMetrics`, `MetricsEngine`, `VitalsUI`, main window: Overview, CPU, Memory, GPU, Storage, Network, Sensors, Processes with quit | A genuinely usable app |
| **M2** | `WidgetCanvas`, composable builder, menu bar | The capability unavailable elsewhere |
| **M3** | `VitalsHelper`: SMART, per-process GPU and power, full process control | Unlocks gated metrics |
| **M4** | Startup, Services, Users, History with `HistoryStore` | Completes Task Manager parity |

M1 must be excellent; it establishes every pattern the rest inherits. M4 follows M3 because
launchd control requires the helper.

---

## 11. Testing

**Fixture replay.** Real output from `ioreg`, `sysctl`, `host_statistics64`, `SPMemoryDataType`,
and `SPNVMeDataType` is captured from live hardware into fixture files and replayed against the
parsers as golden-file tests. Parsing is deterministic and therefore fully testable off-device.

**Hardware profile fixtures** for at least three machines — Apple Silicon unified, Intel with
both integrated and discrete GPUs, and a fanless laptop — so capability-detection paths are
exercised for hardware not physically available.

**Delta arithmetic unit tests** over synthetic counter sequences: first sample, counter
wraparound, monotonicity violation, core count change, interface appearance and disappearance.
This is where tools of this kind break.

**Performance test** asserting engine overhead stays within budget under a representative
subscription load.

**Snapshot tests** for `VitalsUI` chart and glass primitives in light and dark appearance.

---

## 12. Risks

**IOReport is a private framework.** It is what every serious Mac monitor uses for CPU frequency
and power, and it has been stable for years, but it carries no compatibility guarantee. It is
isolated behind a protocol; if it breaks, frequency and power degrade to `unavailable` and
nothing else is affected.

**`powermetrics` output parsing.** Mitigated by consuming its plist output rather than its
human-readable text, which is far more stable across releases.

**Desktop window-level behaviour changes between macOS releases.** Confined to `WidgetCanvas`,
behind a single window-configuration type.

**Vendor trademarks.** The Apple logo is available as a system font glyph. An Intel wordmark
requires a bundled asset. Acceptable for a local build; it would need review before any
distribution.
