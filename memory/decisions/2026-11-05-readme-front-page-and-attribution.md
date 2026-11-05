---
title: README front page images, install status wording and agent attribution
date: 2026-11-05
status: active
tags: [decision, github, documentation, readme, positioning, attribution]
related_files: [README.md, docs/assets/make-readme-images.swift, docs/assets/github-social-preview.png, docs/assets/hero-themes.gif, docs/assets/views-14.png, docs/assets/iphone-themes.png, docs/assets/coin-widgets.png, docs/assets/themes, docs/design/screenshots, app-store/README.md, docs/handoff]
---

## Context

After the November redesign the README still showed the muted July banner, pointed at the October 6 release checkpoint and credited only OpenAI Codex. The owner wanted the front page to show the six colourful themes and the 14 views, and to list the public TestFlight links honestly while Apple's beta review was pending. The handoff log shows both Codex and Claude worked on both apps at different times, so a single-tool story would be wrong.

## Decision

- Every image on the README is composed from the existing synthetic review screenshots (`docs/design/screenshots`) by `docs/assets/make-readme-images.swift` (CoreGraphics, the bundled OFL fonts, no network, no live data). The header of the script lists the commands and output names, including the ffmpeg step for `hero-themes.gif`. The script is the source of the 1280x640 social card `github-social-preview.png`; the old hand-written SVG source was removed because it described the July design.
- The banner, the hero GIF and the iPhone strip show six different views in six different themes, not the Map six times (owner feedback). Mac pairing: Map in Chain colours, Ring in Candy brutal, Bubbles in Riso zine, Calendar in Heatmap, Flow in Pixel, Atlas map in Acid, from `docs/design/screenshots/phase3/mac/portfolio-<view>-<theme>.png` (`MacScreenRenderTests`; `ATLAS_WRITE_SCREENSHOTS=all` renders every view in every theme, `ATLAS_SCREENSHOT_NAMES=portfolio-ring-candy,...` limits it). iPhone pairing differs for Heatmap (Over time, because the Calendar is tiny on a phone): `docs/design/screenshots/phase3/ios/readme-portfolio-<theme>-<mode>-<view>.png`, rendered with the Debug demo fixture (`-AtlasDemoFixture full -display.theme.v1 .. -display.portfolioVisualization.v1 .. -AtlasDemoScrollY 330`), halved to 603x1311. The Theme grid in "Six themes" still shows the Map in each theme on purpose (a like-for-like theme comparison).
- GIF gotcha: do not use `paletteuse=diff_mode=rectangle` for `hero-themes.gif`; it left a wrong-coloured strip at the bottom of one frame (the caption bar is identical between frames). Verify a GIF by decoding every frame with ImageIO and comparing to the source frame PNGs.
- Image budget: each PNG well under 1.5 MB, the GIF under 1 MB (the secret-artifact check rejects tracked files over 4 MiB). Images have opaque backgrounds so they read on GitHub light and dark.
- The install section lists both public TestFlight links with the exact build (0.2.0 (175)) and the state ("in Apple's TestFlight beta review, submitted 2026-11-05; links work once Apple approves"). Update it when `app-store/README.md` records approval, a tester join, or a new build. Link to the checkpoint heading by its GitHub anchor (`#release-checkpoint--november-5-2026`) and never claim device installation, notarized download, or iCloud restore as verified.
- "How it was built" is neutral and per-agent: the owner designed and reviewed; Codex (GPT-5.6) and Claude (Claude Code; Opus 5.5 directing Sonnet 5.5 agents for the November redesign and release) did much of the implementation; `docs/handoff` is the per-session record. Keep "no AI runtime dependency" and "portfolio data is never sent to an AI provider".

## Consequences

- When the screenshots, theme list or the 14 views change, rerun the script and update the counts in the banner chips, the alt text and the tables together. Counts to keep in sync: 20 networks (`ChainRegistry`), 3 exchanges, 6 themes (`AtlasThemeModel`), 14 views (`PortfolioVisualization`).
- This supersedes the attribution rule and the "editable social-card source" rule in `2026-07-21-public-repository-positioning.md`.
- Do not add a screenshot that shows a real wallet address, balance or key; use only the synthetic fixture.
