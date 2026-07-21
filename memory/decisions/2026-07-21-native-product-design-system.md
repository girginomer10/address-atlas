---
title: Native product UI uses a restrained semantic design system
date: 2026-07-21
status: active
tags: [decision, native, swiftui, design-system, accessibility, privacy]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasDesignSystem.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppShellViews.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/PortfolioViews.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ExchangeSyncViews.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/AtlasDesignSystemTests.swift]
---

## Context

The original native interface used pervasive all-caps labels, monospace and
serif styling, hard rectangular outlines, numbered navigation, and terse trust
copy. It read like a generated terminal dashboard and made sensitive exchange
credential setup feel less trustworthy than the underlying security model.

## Decision

- Use semantic surfaces, restrained navy/blue accents, rounded system type, soft
  borders, and hierarchy from spacing and weight rather than decoration.
- Keep the main navigation and page language calm and literal. Privacy claims
  must explain the concrete boundary instead of using slogans.
- Use the appearance-aware `paper` foreground on accent fills so primary actions
  meet normal-text contrast in light, dark, and high-contrast appearances.
- Respect Reduce Motion for page, control, and value transitions; do not make
  essential state depend on animation.
- Every primary surface must render at the minimum supported content width, with
  a compact alternative for data-dense rows that cannot remain legible.
- Sensitive exchange values stay hidden by default. Provider-specific labels,
  permission checks or warnings, encrypted-storage language, and read-only scope
  are part of the connection workflow rather than footnotes.
- When records already exist, show the saved state before long creation forms so
  returning users can act without scrolling through onboarding UI.
- Visual regression fixtures use synthetic encrypted test data only and cover
  empty, populated, compact, light, and dark states without touching a real vault.

## Consequences

- New native screens should compose the shared typography, surface, radius,
  control, status, and motion primitives before introducing local styling.
- Changes to palette or primary controls must retain contrast, keyboard focus,
  Reduce Motion, minimum-width render, and full Swift/Thread Sanitizer coverage.
- Never capture real wallet addresses, balances, API keys, or recovery material
  for screenshots, documentation, tests, or public repository assets.
