# Visual polish — design

Four defects found by watching the running app, not by tests. Every one of them
passed the full 445-test suite. Three of the four actively misinform the reader;
the fourth only reads badly.

Approved by the owner 2026-08-01. Ordered by value: 1, 2, 3 are the
misinforming ones, 4 is cosmetic.

## Evidence

Captured from `build/Vitals.app` at commit c54df8d, window 1031x713, Network
page (selection confirmed through the accessibility API before describing
either capture — an agent on this project once reported a screenshot of a
different page).

- The Network page's first glass panel measures ~351pt of a 713pt window (49%),
  and grows with the window. The chart canvas inside it is ~270pt.
- Hovering the chart's extreme right edge and holding still for two seconds
  renders the readout as `24s ago / Down 0.01 / Up 0.10 MI` — both value rows
  cut off mid-string at the panel edge. **It does not recover.** The correction
  is not merely late; it never arrives.
- The Network chart's tallest peak carries no number anywhere on the page. The
  same shape would be drawn by a 1 MB/s burst and a 900 MB/s one.

## 1. The chart eats the page

**Symptom.** On the four pages whose `secondary` slot is empty or near-empty
(Memory: a one-line caption; GPU: a notice that only appears on multi-GPU;
Network: `EmptyView()`; Storage: volume bars, which on a single-volume Mac is
one thin row), the chart takes roughly half the window and grows without limit.
CPU escapes only because `CoreGrid` fills its secondary slot.

**Mechanism, confirmed in code.** `HardwarePage` pins its content stack to
`minHeight: proxy.size.height` (`HardwarePage.swift:128`) so a trailing spacer
has something to push against on a tall window. `MetricChart` ends with
`.frame(minHeight: Vitals.Metrics.chartHeight, maxHeight: .infinity)`
(`MetricChart.swift:136`). The chart is the only greedy element in that stack,
so every leftover point lands in it.

**Decision.** Fixed ceiling. Not a fraction of window height: that would mean
threading the `GeometryReader`'s height from `HardwarePage` into `MetricChart`,
widening the chart's API for a container's layout concern. Not filling the empty
slots with real content either — that is the right long-term answer and it is a
milestone, not polish.

**Design.**

- Add `Vitals.Metrics.chartMaxHeight: CGFloat = 220`, next to the existing
  `chartHeight = 132` floor.
- Apply it in `HardwarePage` at the point the chart is constructed, as
  `.frame(maxHeight: Vitals.Metrics.chartMaxHeight)`. The chart then lives in
  132...220: the outer frame proposes at most 220, the inner `minHeight` holds
  the floor.
- **Not** inside `MetricChart`. Overview tiles embed the same chart and size it
  from the tile's own geometry; capping there would reach into a caller that
  does not have this problem.
- The freed height falls to the existing `Spacer(minLength: 0)` at
  `HardwarePage.swift:126`, which is what it was written for.

**Consequence, stated plainly.** On a very tall window the space below *Full
specifications* becomes genuinely empty. That is the accepted cost of this
option; the alternative was giving four pages new secondary content.

**Tests.** A render-harness test at two window heights asserting the chart's
drawn height is equal at both and does not exceed 220. It must be watched
failing with the cap removed.

## 2. The crosshair readout clips off the right edge

**Symptom.** Reproduced above and it is permanent, not transient.

**Mechanism, confirmed.** `ChartGeometry.readoutOrigin` (`ChartScrubber.swift:73`)
is correct — given a correct `boxSize`. `MetricChart` feeds it `readoutSize`,
`@State` seeded at `.zero` and updated through a `ReadoutSizeKey` preference.
With `boxSize == .zero` the maths reduces to `idealX = x - margin` clamped
against `rect.maxX - 0`, i.e. the box's top-left lands 8pt left of the cursor
and it extends its full width past the edge. The observation that a stationary
cursor never recovers says the preference-to-state round trip does not
re-position the box at all here.

**Decision.** Stop routing a measurement through view state. The maths is not
the bug and stays; the measurement channel is the bug and goes.

**Design.**

- A small `Layout` conformance placing a single subview: it receives the
  container bounds and can ask `subviews[0].sizeThatFits(.unspecified)` in the
  same call, so it has a real size and the real bounds together, on the first
  frame, with no state and no second pass.
- It calls the existing `ChartGeometry.readoutOrigin` with that measured size.
  `readoutOrigin` keeps its current signature and all of its existing tests —
  this change gives it the input it was always supposed to get.
- Delete `ReadoutSizeKey`, the `readoutSize` `@State`, the `.background`
  `GeometryReader`, the `.onPreferenceChange`, and the `.offset`.

**Why this over the alternatives.** Seeding a non-zero estimate leaves one frame
wrong and requires inventing a size — too close to this project's founding rule
to be comfortable. `onGeometryChange` still measures `.zero` on the first frame,
so it may not touch the reported symptom at all.

**Tests.** Hover at the extreme right of a chart in the render harness and
assert the readout's right edge is within the chart's bounds; the same at the
extreme left. Both must be watched failing against the current code — and the
current code is already known to fail them, which is the ideal starting point.

## 3. Absolute-unit charts have no y-max

**Symptom.** Storage and Network scale to their own peak with nothing labelled,
so an idle link and a saturated one draw the same picture.

**Second defect in the same place.** Because the bound *is* the peak, it moves
on every tick: the entire chart reshapes each sample even when the underlying
traffic is steady. Labelling a bound that jitters would produce a number
flickering between `41.25 MB/s` and `38.92 MB/s`, which is worse than no label.
So the bound and the label have to be fixed together.

**Decision.** Round the bound up to a nice value, then label that.

**Design.**

- `ChartGeometry.niceUpperBound(_ peak: Double) -> Double`: the smallest
  `m x 10^n` with `m` in `{1, 2, 5, 10}` that is at least `peak`.
  - `10` is in that list deliberately. `log10`/`pow` round-tripping is not
    exact — `log10(0.001)` can land at `-3.0000000000000004`, whose floor is
    `-4`, giving a mantissa of `10.0` that `{1, 2, 5}` alone cannot cover. This
    project has been bitten by float equality four times; the list absorbs it.
  - After computing, verify `bound >= peak` and step to the next multiplier if
    floating-point error left it a hair short. A bound below the peak would clip
    real data, which is the same class of error as inventing it.
  - Worked cases: `41.25 -> 50`, `0.12 -> 0.2`, `0.03 -> 0.05`, `10 -> 10`,
    `0.001 -> 0.001`.
- `upperBound(for:unit:)` uses it for `.absolute` only. `.fraction` keeps
  `max(peak, 1.0)` untouched — 100% is already a known ceiling and CPU, Memory
  and GPU all show it as a headline number.
- The label's decimal count is derived, not guessed: for a bound `m x 10^n` it
  is `max(0, -n)`. `50 -> "50"`, `0.2 -> "0.2"`, `0.05 -> "0.05"`,
  `0.001 -> "0.001"`. The existing `ChartUnit.absolute` formatter is `%.2f`,
  which would render a 0.001 ceiling as `0.00 MB/s` — a ceiling of zero on a
  chart that is visibly not flat. It is not reused here.
- Drawn inside the `Canvas`, at the plot rect's top-leading corner, in
  `Typography.label` at secondary emphasis. Absolute-unit charts only.

**Known interaction, accepted.** With the cursor in the chart's left half the
readout is anchored to the right of the cursor and can overlap this label. The
readout is a transient hover state on an opaque glass background and is drawn
over the canvas, so it wins. Moving the readout to avoid a static label is not
worth the coupling.

**Tests.** `niceUpperBound` is pure and carries the coverage: the worked cases
above, the `>= peak` invariant across a generated range, and the `0.001`
float-error case specifically. Plus a render assertion that a Network chart
draws a label and a CPU chart does not.

## 4. Processes cold start

**Symptom.** For the first 5-10 seconds the rate columns are a column of em
dashes. The behaviour is correct — sampling is subscription-driven and
`ProcessCPUTracker` needs two samples to compute a rate — but it reads as
breakage.

**Decision.** Say what is happening. Do not fill the cells.

**Design.** A single caption between `header` and the table in `ProcessesPage`,
in `Typography.label` at secondary emphasis, shown only while
`store.processes != nil && store.processes?.cpuUsage.isEmpty == true`. That is
the codebase's own existing notion of "listing arrived, rates have not" — the
same condition `ProcessesPage.swift:195` already watches to re-sort. Wording:
*Measuring — CPU and disk rates need a second sample.*

It disappears on its own the moment the second sample lands. No per-cell change,
no animation, no invented values: the dashes stay honest and the caption
explains them.

**Tests.** Caption present with a listing and empty `cpuUsage`; absent once
`cpuUsage` is populated; absent when `store.processes` is nil (that state
already has its own "No process listing available." message and must not show
both).

## Non-goals

- Filling the four empty `secondary` slots with real content. The right fix for
  the root cause of item 1, and a milestone of its own.
- Any change to fractional charts' scaling.
- The Processes `selection:` binding, the `ProcessComparator` NaN edge, and the
  stale AGENTS.md line claiming the Overview has only CPU and Memory tiles — it
  has all five as of c54df8d. Noted, not in scope here.

## Risks

- Item 3 touches `upperBound`, which every chart calls. The `.fraction` path
  must be provably untouched, not merely believed to be.
- Item 2 deletes a working-looking mechanism. If the render harness cannot
  reproduce the clip (it renders through `NSHostingView`, and hover is
  synthetic), the test may pass vacuously — six tests on this project already
  turned out to prove nothing. If the harness cannot drive a real hover, the
  test asserts on `readoutOrigin` plus a `Layout` unit test instead, and the
  visual check carries the rest. That fallback is a deliberate choice to be
  recorded, not a silent downgrade.
