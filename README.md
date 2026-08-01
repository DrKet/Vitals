# Vitals

A macOS system monitor. Live CPU, memory, GPU, storage and network readings, with
per-subsystem detail pages. Native SwiftUI, no third-party dependencies.

![The Vitals overview, showing live CPU, memory, GPU, storage and network tiles](docs/images/overview.png)

## Download

Grab the latest `Vitals-<version>.zip` from
[Releases](https://github.com/DrKet/Vitals/releases), unzip, and move
`Vitals.app` to your Applications folder.

**macOS 26 or later is required.** On anything older the app will not launch.

### The first time you open it

Vitals is signed ad-hoc, not with a paid Apple Developer certificate, so
macOS will say:

> "Apple could not verify Vitals is free of malware."

That is Gatekeeper telling you the truth: this app has not been notarized by
Apple. To open it anyway, either:

- **right-click** `Vitals.app` → **Open** → **Open**, once; or
- run `xattr -dr com.apple.quarantine /Applications/Vitals.app`

You only need to do this once. If you would rather not, build from source
instead — the instructions below produce the same app.

## Requirements

- **macOS 26.0 or later.** This is a hard floor set in `Package.swift`, not a
  suggestion — the app builds against APIs that do not exist on earlier releases.
  On an older macOS it will not compile.
- **A Swift 6 toolchain.** Developed and tested on Swift 6.3.3, targeting
  `arm64-apple-macosx26.0`.
- An Apple Silicon or Intel Mac. Developed on Apple Silicon; the Intel paths for
  memory and GPU topology exist and are unit-tested against captured fixtures,
  but have not been run on real Intel hardware.

## Running it

The easiest way is the [Download](#download) section above. To build from
source instead:

```bash
git clone https://github.com/DrKet/Vitals.git
cd Vitals
./scripts/build-app.sh
open build/Vitals.app
```

First build takes a minute or two. This produces the same ad-hoc-signed
bundle as a Release download, so the Gatekeeper warning above still applies.

To see the raw sampler output without any UI:

```bash
cd VitalsCore
swift run vitals-dump
```

And to run the tests:

```bash
cd VitalsCore
swift test
```

## What's built

| Page | State |
|---|---|
| Overview | Live tiles for all five subsystems |
| Processes | Sortable live table — CPU, memory, threads, user, PID, with heat shading |
| CPU | Per-cluster load, core grid, topology, cache, uptime |
| Memory | Wired / App / Compressed / Cached breakdown, swap, pressure |
| GPU | Renderer / Tiler utilisation, memory topology |
| Storage | Read / write throughput, volume capacity, device name |
| Network | Down / up throughput, active interfaces |

Every hardware page has a live chart with a scrubbing crosshair that reads values
back with their age, and a sticky *Full specifications* section.

**Not built yet:** the Sensors page (temperatures, fans and power need a private
framework and an empirical spike), desktop widgets, the menu-bar extra, a
privileged helper for per-process GPU and SMART health, and the Startup /
Services / Users / History pages. Those sidebar entries are visible but show a
placeholder.

The Processes table is read-only for now — no context menu, no process tree, no
inspector.

## The rule the whole thing is built around

**Never fabricate a number.**

If a value cannot be measured it is `nil`, and it renders as "Unavailable" or an
em dash — never `0`, never blank, never a plausible-looking guess. A series with
no reading is omitted from its chart rather than drawn as a flat zero band, because
a flat zero band is a measurement the machine never reported.

That sounds obvious and is surprisingly invasive. It means a sampler throws rather
than returning an empty result; a device missing from one sampling tick counts as
*no reading* rather than zero; an out-of-range driver value becomes `nil` instead
of being clamped into something believable; a reading that cannot be attributed to
the right GPU is withheld rather than labelled with the wrong device's name; and
the chart renderer clamps its own smoothing so a curve never draws above the
samples it interpolates.

If you find somewhere it *does* invent a number, that's a bug worth reporting.

## Layout

```
VitalsCore/Sources/
  SystemMetrics/   Mach, sysctl and IOKit sampling. No UI, no scheduling.
  MetricsEngine/   An actor scheduling samplers on cadences.
  VitalsUI/        SwiftUI views, charts, design tokens.
  VitalsApp/       The app executable.
  vitals-dump/     CLI for eyeballing live sampler output.
docs/              Design spec and implementation plans.
```

Sampling is subscription-driven: nothing is sampled unless a view is watching it,
and closing a page stops it. Charts break their line where sampling paused rather
than drawing a straight segment across the gap.

## Contributing

Read [AGENTS.md](AGENTS.md) first. It documents the conventions, the platform
gotchas, and several traps that have already cost real time here — including three
separate occasions when a class of test turned out to prove nothing.

Two that will bite you immediately:

- Warning checks need `rm -rf .build` first. An incremental build does not
  re-emit warnings for unchanged files, so a plain `swift build` reports clean
  regardless of what is there.
- `swift test --filter` matches type identifiers, not `@Suite` display names.
  `--filter MemoryPageTests` works; `--filter "Memory page"` matches zero tests
  **and still reports success**.

## Status

Early. The foundation, the five hardware pages and the Processes table are
complete and tested, but this is not a finished app — there's no menu-bar extra
or desktop widgets yet, and several sidebar entries are placeholders. Bug
reports and observations from actually running it are the most useful thing
right now, particularly anything that looks like a fabricated number.
