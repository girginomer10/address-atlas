---
title: A power-diagram treemap can swallow a cell unless weights keep every site inside its own cell
date: 2026-11-04
status: active
tags: [gotcha, charts, geometry, tests]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/PowerDiagramTreemap.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/PowerDiagramTreemapTests.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartTestFixture.swift]
---

## Gotcha

The atlas map lays cells out as a weighted Voronoi (power diagram) and corrects each weight by the area shortfall. With some seeds two sites start close together, the heavier one's cell swallows the other whole (area 0), and the plain correction cannot bring it back (a vanished cell has no edges to measure its response from). One synthetic portfolio did this (USDC cell area 0, area error over 200%) while the original fixture happened to converge, so the first tests passed.

Tiny targets are also ill-conditioned: a slice worth 0.01% of the total has a target of a few dozen points of area, and no relative error means anything there.

## Safe practice

- After every weight update (and after every Lloyd move) the solver raises each weight to at least `weight(j) - 0.97 * distance(i, j)^2` over all other sites, which keeps each site inside its own cell, so no cell can vanish.
- `PowerDiagramTreemap.layout` retries from up to three more seeds when the first arrangement misses the 2% target and keeps the best; errors are measured against `max(target, 0.2% of the boundary)` so unreadable slivers do not force retries. The atlas view still folds slices under 1% (3% compact) into "Other".
- When changing the solver, keep `testManyShapesConvergeAndNoCellVanishes` (sizes 4 to 30, two skews, six seeds) green and run the chart tests against more than one fixture shape. 30 items take about 100 ms in a debug build and 5 to 6 ms in release.
- Wall-clock budgets (`testThirtySlicesLayOutQuickly` here and in `AtlasMapChartViewTests`) are skipped under Thread Sanitizer via `TestSanitizer.isThreadSanitizerActive` (`SanitizerSupport.swift`). CI runs `swift test --sanitize=thread`, where the debug layout took 1.9 to 2.3 s and broke the 1.5 s budget on every main push from 2026-11-04 until the guard landed. New timing assertions in the Mac test target should use the same guard.
