# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- macOS notifications: one when a batch of activations finishes (activated, skipped, failed, with
  the expiry), and a reminder 10 minutes before activated roles expire. Shown while the app is
  frontmost too.
- Settings window (⌘,):
  - Notifications: completion notifications on/off or only on failures, sound, expiry reminders
    on/off and lead time (5/10/15/30 min), permission state with a link to System Settings, and a
    test notification. Turning reminders off cancels pending ones; a new lead time reschedules them.
  - Activation: default duration, parallel requests (1-16, default 8), Owner confirmation
    (still on by default), recent justifications offered from a menu next to the field, optional
    prefill of the last one.
  - General: tenant to open with, load on launch, auto-refresh (off/1/5/15 min), Type/Membership/
    Condition columns.
  - Reset to defaults.
- Searchable tenant picker (⇧⌘T or the toolbar): tenants sorted by name with domain and short ID,
  checkmark on the current one, "Use az default", manual entry and reload. Tenants you never use can
  be hidden. With `--tenant`/`PIMENTO_TENANT` it opens locked with an explanation.
- Table columns can be hidden by right-clicking a column header; the layout is remembered.

### Changed

- **Activate** always sends for real; the dry-run mode switch is gone. **Preview** (⌥⌘↩, also in the
  View menu) shows the requests without sending them. The Owner confirmation is unchanged.
- The tenant picker in the toolbar no longer looks disabled.
- Tenant names come from ARM's `GET /tenants` first, so tenants without a subscription show their
  name instead of a bare GUID (`--tenants` too). Tenants nobody names read "Unnamed tenant" plus a
  short ID and sort last.
- Long resource, role and group names are truncated with a tooltip instead of wrapping.
- With "Load roles on launch" off, the window says so and offers Refresh instead of a spinner.

### Fixed

- A role activated from the app showed "Eligible" until the next manual refresh, because
  Azure lists a new activation only after a few seconds. It now shows as active right away
  (with the expiry Azure returned), leaves the selection, and the list is re-checked 20 s
  later.

## [0.1.0] - 2026-10-29

### Added

- Native macOS app (SwiftUI, macOS 14+) listing every Azure-resource PIM eligibility of the
  signed-in user, including group-inherited ones, with active state and expiry.
- Bulk activation with one justification and duration (1-24 h), at most 8 requests in parallel,
  with per-row results and policy-rule explanations.
- Dry run (on by default), showing the exact request URLs and bodies.
- Confirmation before activating Owner roles.
- ABAC conditions on eligibilities are copied into the activation request.
- Tenant selection: `--tenant`, `PIMENTO_TENANT`, a remembered choice in the app, or az's
  current tenant; the toolbar lists the tenants az knows about.
- Read-only CLI mode in the same binary: `--list`, `--dry-run`, `--tenants`, `--version`.
- App icon generated with CoreGraphics (`scripts/make-icon.swift`), bundling script,
  GitHub Actions CI and release workflow.

[Unreleased]: https://github.com/melvin2306/pimento/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/melvin2306/pimento/releases/tag/v0.1.0
