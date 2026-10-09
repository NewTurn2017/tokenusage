# Token Usage Popover Design System

## Design read

This is a native macOS menu-bar utility for people scanning several AI accounts many times a
day. The redesign is an overhaul of the visual hierarchy, not the product structure: it uses a
compact, colourful, information-first language while preserving every quota window, state, and
account action. The working dials are variance 4, motion 2, and density 9. Native platform
behaviour, legibility, and accessibility take priority over decorative web patterns.

## Existing audit

- The app already uses semantic SwiftUI colours, system typography, SF Symbols, a 4-point spacing
  scale, 10-point continuous corners, and native controls.
- The current popover is 344 points wide. It repeats large cards for quota values and uses another
  full card for every Codex account, creating a roughly 960-point-tall common state.
- Provider marks, Korean copy, accessibility identifiers, profile pickers, login/save/delete
  actions, stale/error handling, bounded account scrolling, and light/dark adaptation are product
  behaviours to preserve.
- The reset-coupon count is uncommitted work. Zero is meaningful; missing data must remain absent.

## Tokens

- Spacing follows a 4-point grid: `2xs` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16.
- Type uses San Francisco through semantic SwiftUI styles. Numbers use monospaced digits for fast
  vertical comparison. No text is smaller than the system caption style.
- Provider accents are semantic system colours: Claude orange, Codex teal, OpenRouter indigo.
  Low quota overrides provider colour with system orange at 25% and system red at 10%.
- Surfaces and dividers derive from `Color.primary` opacity, so hierarchy survives Aqua and Dark
  Aqua. One 10-point container radius is used; small status and count badges are capsules.
- Progress tracks are 3 points high. Provider icons are 14 points; compact action icons are 12.

## Composition

- The header is one line: title and refresh state at left, activity at right.
- Each provider owns one softly tinted section rather than a card per metric.
- Account rows are scan-first: identity/state on the first line; quota, thin bar, reset, and coupon
  metadata directly below. Every Claude account row shows its 5-hour window, then whichever
  weekly limits that account's plan reports: weekly, Fable, or both. Team plans report no
  all-model weekly limit, so their Fable window and reset take the weekly slot. Row values are
  bare percentages because the popover title already says they are what remains.
- Account save/new-login/delete actions live in labelled provider menus. Opening an action reveals
  the existing native editor inline; destructive confirmation remains native.
- Unconfigured OpenRouter uses one compact line. Errors remain visible above the footer actions.
- Codex lists show three rows before scrolling and Claude lists five (one Max account beside four
  Team seats). The popover grows row by row up to that limit and is capped after that, staying
  under a 14-inch laptop's visible height.
- The menu bar keeps one column per Claude account: 5-hour over weekly, or over Fable when the
  plan has no weekly limit.

## Native behaviour and QA

- Appearance follows macOS; there is no app-specific theme switch.
- Colour never carries status alone: low quota has `주의` or `부족`, pace retains its text label,
  and freshness remains visible.
- Names and reset labels truncate only after receiving layout priority; full values remain in the
