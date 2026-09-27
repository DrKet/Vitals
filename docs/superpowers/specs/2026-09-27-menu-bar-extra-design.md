# Menu-bar extra — first slice

The original design (§8) makes the menu bar "the primary daily interaction; the
window is for investigation". Vitals has no menu-bar presence yet, and today it
quits when its window closes. This slice adds a live menu-bar readout and a
glance dropdown, and changes the app's lifecycle so it keeps running in the menu
bar without a window.

## Scope

In:

- A menu-bar readout: CPU and memory, a fixed set.
- A dropdown panel: one row per kept-warm subsystem — CPU, Memory, GPU,
  Storage, Network — each with its headline value and a sparkline; clicking a
  row opens the main window on that page. Footer: **Open Vitals**, **Quit
  Vitals**.
- Lifecycle: closing the window keeps Vitals running in the menu bar; the Dock
  icon is present only while the main window is open.

Out — later slices:

- Configurable readouts (§8's "any combination of CPU, memory, GPU, network,
  temperature, and power"). Power is not measurable yet (IOReport, §4.6).
- Top processes in the dropdown, quittable in place. The process sampler is the
  expensive series; it needs its own throttling decision.
- Throttling while the dropdown is closed; pausing while the menu bar is hidden
  in fullscreen.
- Settings and the Edit Widgets toggle.
- Battery and Sensors rows: not kept warm, so they would need their own
  subscription while the dropdown is open. YAGNI for this slice.

## Decisions

**SwiftUI `MenuBarExtra`, window style.** A scene beside the existing
`WindowGroup`: its label is the readout, its content the dropdown. The original
spec named an AppKit `NSStatusItem` hosting SwiftUI; that stays the fallback if
the SwiftUI label turns out too restricted (see Risks), and would replace the
label only.

**Dock icon only while the main window is open.** Closing the window switches
the app to the accessory activation policy: no Dock icon, no Cmd-Tab entry, the
menu-bar item remains. Opening the window (from the dropdown, or a row) switches
back to regular. Quit is in the dropdown footer and the app menu's ⌘Q.

**Readout format: symbol + value pairs, monospaced digits.** `cpu` then the CPU
value, `memorychip` then the memory value. An unmeasured value is an em dash,
exactly as a tile words absence.

**Memory in the menu bar is a percentage** — used over total — where the
Overview tile's headline is gigabytes. A percentage fits the compact slot, and
the value is the tile's own bar fraction (`OverviewPage.memoryFraction`), so the
two cannot disagree. With no reported total there is no whole to be a fraction
of: the readout shows an em dash, never a guess.

**Never fabricate, including in the menu bar.** The store already clears live
fields once they go stale, so a sampler that stops leaves "—" in the menu bar,
not a frozen number.

## Architecture

### Store, sampling and navigation move up to the app

Today `VitalsApp` builds the engine and store inside the window's `.task`, and
`AppShell` starts `store.keepWarm()`. Both would die with the window.

- `VitalsApp` builds the engine and `MetricsStore` once at launch and holds it
  at app level; the window and the menu-bar extra receive the same instance. A
  reopened window must never rebuild it.
- `keepWarm()` moves from `AppShell` to the app, and runs for the app's
  lifetime. It covers exactly the series the readout and dropdown show (CPU,
  memory, GPU, network, disk I/O) at the same cheap 1 Hz cadence already kept
  warm today, so this adds no sampling cost.
- The selected sidebar page moves to the app too. `AppShell` gains an
  `init(store:selection:)` taking a `Binding<SidebarSection>`; the existing
  `init(store:)` keeps its own local selection, so its callers are unchanged.

A startup failure (hardware profile unreadable) keeps today's behaviour in the
window — the message is shown — and the menu-bar label shows em dashes.

### Lifecycle

- `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns
  `false`.
- The activation policy follows the main window: a pure
  `activationPolicy(mainWindowOpen: Bool) -> NSApplication.ActivationPolicy`
  (`.regular` when open, `.accessory` when not), applied when the main window
  opens and closes.
- **Open Vitals** and row clicks: set the selection (rows only), open or raise
  the main window via SwiftUI's `openWindow`, apply `.regular`, and activate
  the app.
- The doc comment on `AppDelegate` and AGENTS.md's Platform note currently
  describe a lingering windowless process as a failure mode. They are reworded:
  a windowless Vitals is now intended, and is always visible in the menu bar.
  The trap they warn about — an unbundled executable launching background-only
  with zero windows *and no menu-bar item* — is unchanged and stays documented.

### Shared tile model

`OverviewPage` builds each tile's label, value, accent, fraction and series
inline in the view. That construction is lifted into one function both the
Overview and the dropdown call, so the dropdown's "GPU 34%" is provably the
Overview's — including the multi-GPU attribution gate that withholds readings
it cannot attribute. The Overview's existing tests must pass unchanged.

### New types (VitalsUI, `MenuBar/`)

- `MenuBarReadout` — pure: the CPU and memory strings, and their absence.
  Reuses the Overview's CPU expression and `memoryFraction`, and
  `MetricTile.displayValue` for absence.
- `MenuBarLabel` — the readout view.
- `MenuBarPanel` — the dropdown: five rows from the shared tile model, and the
  footer. Takes closures for "open page" and "quit", so it renders in tests
  without an app.

## Testing

Every test is watched failing before its implementation exists; `--filter`
uses type identifiers; a render assertion inside a panel uses
`regionHasSaturatedColor`, never `regionHasContent`.

- `MenuBarReadout`: CPU and memory values; an em dash for no sample, and for
  memory without a reported total (or a zero total).
- `activationPolicy(mainWindowOpen:)`: both cases.
- Shared tile model: the Overview's existing tests, unchanged, are the
  regression proof of the refactor.
- `MenuBarPanel` render (off-screen harness, live store fixture): five rows;
  each row's sparkline paints its own accent hue
  (`regionHasSaturatedColor(matchingHueOf:)`); an empty store renders em
  dashes, not zeros.
- Live check, by the owner from a checklist (not synthesized clicks):
  the readout updates; closing the window keeps the readout and removes the
  Dock icon; Open Vitals and each row reopen the window on the right page with
  the Dock icon back; Quit exits; `scripts/verify-app.sh` still passes.

## Risks, checked first

1. **Label styling.** `MenuBarExtra` labels render in a restricted way. The
   first task is a spike rendering the real label in the bundled app: two
   symbol+value pairs with monospaced digits. If it is badly limited, the label
   (only) moves to an `NSStatusItem` hosting the same `MenuBarLabel`.
2. **Reopening a closed window** through `WindowGroup` + `openWindow` must not
   rebuild the store — guaranteed by holding it at app level, and checked live.
3. **`verify-app.sh`** counts the launched process's windows and then quits it.
   The main window still opens at launch, and an explicit quit still quits with
   `applicationShouldTerminateAfterLastWindowClosed` false; confirmed by running
   it.

## Addendum (during implementation)

A few points below diverged from, or sharpened, the design above once it met
the SDK and a live app:

- **`Window`, not `WindowGroup`.** A single `Window("Vitals", id:
  MainWindow.id)` scene, so `openWindow(id:)` always raises the one main
  window rather than risking a second instance.
- **`.defaultLaunchBehavior(.presented)`** is set on that `Window` scene, to
  hold it open on every launch. Without it, SwiftUI's state restoration could
  relaunch straight into "window closed" — the state Vitals can now be quit
  from or left running in the menu bar in — leaving `.onAppear` never firing
  and the bundle's default `.regular` activation policy stuck with a Dock
  icon and nothing to show for it.
- **The engine starts from `App.init`**, the one call SwiftUI runs exactly
  once per process, with idempotent `.task { await model.startIfNeeded() }`
  calls on both the menu-bar label and the main window as backups — not the
  trigger this depends on. See `AppModel.startIfNeeded()`.
- **`MetricChart(minimumHeight:)` and `reservesTrailingLiveDotRoom`** exist
  for the dropdown's compact sparkline: a 28pt floor instead of the usual
  132pt, and a plot rect inset by the live dot's own halo radius so the dot
  never clips against `Canvas`'s raster bounds.
- **Menu-bar values are padded with leading figure spaces** (U+2007) to a
  fixed three digits, so the item's width holds steady as a reading moves
  between one, two and three digits — `.monospacedDigit()` alone equalises
  digit widths, not digit count.
