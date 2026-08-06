# Overview — bar + spark tiles that fill the window

The Overview tiles grow too tall in a wide window. The grid divides height
equally across rows with no ceiling, and at ~1512pt wide all five tiles fit a
single row — so each tile becomes the full window height.

This reworks the Overview into the layout chosen from ten studies (variant 14):
tiles carrying a **proportion bar and a sparkline**, a grid that never
collapses to one row, and **Battery** as a sixth tile on machines that have
one. Verified as mockups against the real components at both window sizes.

## Scope

The Overview page only. No sampler changes, no new metrics beyond surfacing
Battery — which the store already samples for the Battery page. Nothing
destructive.

## Decisions

All four were settled before this was written, two of them by the owner.

**The proportion bar shows only where a real whole exists.** A bar implies a
denominator. CPU load, Memory used, GPU utilisation and Battery charge are each
a measured fraction of a known whole, so they get a bar. Storage and Network
are throughput — bytes per second with no ceiling — so they get none. Inventing
a denominator for them would be the same fabrication the project's one rule
forbids, exactly as `ChartGeometry` already refuses a zero-based bound for
throughput.

The bar also disappears when the value itself is unmeasured. GPU utilisation
that cannot be attributed to a device is `nil` today and headlines as an em
dash; its bar is absent too, never a zero-length bar, which would read as
"0%" — a measurement the machine never made.

**The grid caps its columns.** Column count is derived from width as now, then
capped at three. The cap is what guarantees the fix: five or six tiles can
never form a single row, because three columns forces at least two rows. A
minimum tile width of ~420pt sets the 2-vs-3 breakpoint, giving two columns in
a typical window and three at fullscreen — the behaviour the approved mockup
showed — while the cap keeps an ultrawide display from stranding a lopsided
five-plus-one row.

**Tiles fill the window height, up to a maximum** (owner's call). Rows divide
available height equally, as today, so a normal fullscreen window is filled
edge to edge — the state the mockup was approved in. A maximum tile height,
mirroring `Metrics.chartMaxHeight` on the hardware pages, engages only on an
unusually tall window (a portrait display, a tall resize), where unbounded
growth would recreate the original complaint one row later. The maximum is set
generously enough that the approved fullscreen look is unchanged; it is a
backstop, not a visible constraint at ordinary sizes.

**Battery is a conditional sixth tile** (owner's call on the desktop case).
Six tiles divide into a clean grid where five leave a gap; Battery is the
natural sixth because the store already samples it. It appears only when
`profile.hasBattery`, and the Overview subscribes to `.battery` only then.
On a desktop Mac the five remaining tiles fill left to right and the
bottom-right cell is empty — tiles keep one width and stay aligned across rows,
rather than the short row stretching to a different width.

## Architecture

Three changes, each small and each landing behind a test.

**`TileLayout.columnCount` gains a maximum.** A `maximum:` parameter, capping
the width-derived count. Pure arithmetic, and `TileLayoutTests` already pins
the width breakpoints — this adds the cap's own cases. The existing callers
that pass no maximum keep today's behaviour, so nothing else in the app shifts.

**`MetricTile` gains an optional `fraction: Double?`.** When non-nil the tile
draws a proportion bar between the value and the sparkline, filled to that
fraction in the tile's accent; when nil it draws nothing there, preserving the
current label/value/chart tile exactly. The default is nil, so the parameter is
additive and the one caller (`OverviewPage`, confirmed the only user) opts in
per tile. The Overview bar is a plain accent fill, not the Battery page's
warning-aware `BatteryLevelBar`: the Overview is a glance surface and the
tile's own value carries the number. Warning-coloured bars on the Overview are
a possible later refinement, noted and deliberately out of scope.

**The height cap lives in the grid, not the tile.** `TileGrid` constrains each
row's height to a new `Metrics.overviewTileMaxHeight` token, the same way
`HardwarePage` holds its chart to `chartMaxHeight` rather than `MetricChart`
owning its own ceiling — a layout limit belongs to the container that knows the
window, not the leaf. Below the cap the rows still divide height equally and
fill; at the cap the grid tops out and leaves space below. The token is set
generously enough that an ordinary fullscreen window sits under it, so the
approved look is unchanged.

**`OverviewPage` supplies the fraction per tile, and Battery conditionally.**
The internal `Tile` model gains a `fraction: Double?`:

- CPU — `cpu.total`
- Memory — `used / totalBytes` (already computed for the memory series)
- GPU — the attributable device utilisation, through the existing
  `gpuTileValue` gate, so the bar inherits the multi-GPU attribution rule for
  free and is `nil` exactly when the value is
- Battery — `chargePercent / 100`
- Storage, Network — `nil`

The Battery tile is appended only when `store.profile?.hasBattery == true`, and
a `.task { await store.stream(.battery) }` is added under the same condition so
a desktop never subscribes to a series it cannot show.

## Testing

Pure logic first, watched failing before implementation, per the project's
standing lesson that a brief is a draft and a green-on-first-run test has
proved nothing.

- **`columnCount` cap** — a width that would yield five columns returns three
  when capped at three; a width yielding two is unchanged by the cap (the cap
  only ever lowers). Mutation check: removing the cap must redden the
  five-to-three case.
- **The bar's presence is exactly the fraction's presence.** A tile given a
  fraction renders a saturated bar region; a tile given `nil` renders none.
  This is the assertion that encodes "no bar without a whole", so it carries
  the weight and gets the mutation check — forcing the bar to draw regardless
  of fraction must redden the nil case. Uses `regionHasSaturatedColor` inside
  the panel, per the render-harness rules in AGENTS.md.
- **The Overview wires each metric to the right fraction** — CPU/Memory/GPU/
  Battery non-nil, Storage/Network nil — exercised through the pure tile model
  the way `OverviewPageTests` already exercises the GPU and Network gates,
  without rendering the whole grid. Includes the GPU-unattributable case
  returning nil.
- **Battery is present only with a battery** — the tile list built from a
  profile with `hasBattery` true includes it; false omits it.

`MetricTile` gains no stored property on a `SystemMetrics` struct, so the
incremental-build SIGSEGV trap does not apply here — but the render tests need
a GUI session and a clean build is cheap, so the suite is run after
`rm -rf .build` regardless.

## Out of scope

Warning-coloured Overview bars; any change to the hardware pages, the sampler,
or the Battery page; the five-tile desktop layout beyond the empty-slot rule
above. Reordering tiles or changing which metrics appear (beyond Battery).
