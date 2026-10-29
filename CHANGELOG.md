# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- End activations early and renew them.
  - **Deactivate** (`SelfDeactivate`): check active rows (they can be checked now) or right-click a
    row, then *Deactivate* / *End Now…* (⇧⌘E), with a confirmation. Roles activated less than 5 minutes
    ago are not sent and show *Too soon* with the time from which PIM allows it (PIM answers
    `RoleAssignmentDoesNotExist` then; `ActiveDurationTooShort` is handled the same way).
  - **Renew**: deactivate, then activate again for the chosen duration (capped at the policy
    maximum), with a confirmation that warns about the gap and lists Owner roles (⇧⌘R). PIM refuses
    the new activation (`RoleAssignmentExists`) until it has removed the old one, about 3 minutes in
    tests; Pimento retries for 5 minutes and shows the attempts. Roles whose policy requires
    approval are not renewed.
  - Ended and renewed rows keep their new state while Azure catches up (refresh now, after 20 and
    60 seconds); per-row results and a completion notification for both.
  - CLI: `pimento deactivate` and `pimento renew` (FILTER…, `--role`, `--all` or `--preset`;
    `--yes`, `--dry-run`, `--json`, same prompts and exit codes as `activate`), and `pimento extend`,
    which sends `SelfExtend` for admin-assigned time-bound assignments (`--days`, default 30): a
    request an administrator must approve. Activations are left out with a pointer to `renew`,
    because PIM files `SelfExtend` on an activation as `PendingAdminDecision` and keeps its end time.
  - Expiry reminders have **Renew** and **End Now** actions. Renew reuses the duration and, when
    recent justifications are kept, the justification; otherwise, or for Owner roles, the app asks.
    Reminders of ended roles are withdrawn or rewritten; renewed roles get new ones.

- Presets: named sets of roles with an optional justification and duration, per tenant.
  - App: a Presets toolbar menu and menu-bar menu. Picking a preset (⌘1–⌘9) checks exactly its
    roles and fills in its justification and duration; *Activate Preset* also activates (Owner
    confirmation unchanged). *Save Selection as Preset…* (⇧⌘S) and *Manage Presets…* (rename, edit
    justification/duration/roles including active ones, remove missing roles, delete).
  - CLI: `pimento activate --preset NAME` (preset justification and duration unless `-j`/`--hours`),
    `pimento presets list|show|save|delete`. `presets save NAME FILTER… [--role …]` stores a rule
    resolved at activation time; `--exact` stores the roles that match now.
  - Roles are identified by scope + role definition GUID (case-insensitive). Roles you are no longer
    eligible for are reported as missing and the rest is activated.
  - Shared file `~/Library/Application Support/Pimento/presets.json` (versioned JSON, mode 600);
    `PIMENTO_PRESETS` points the CLI (or a terminal-launched app) at another file.
- Each role's PIM policy is read (`roleManagementPolicyAssignments`, end-user activation rules:
  maximum duration, justification, ticket, MFA, approval, authentication context), a few requests at
  a time and cached for the session. Requests use `min(asked, policy maximum)`, so `ExpirationRule`
  failures no longer happen when the policy is readable; if it is not, the asked duration is used.
  - App: a Duration column (`max 8 h`; for checked rows `8 h (max 8 h)`, orange when capped; the
    tooltip lists the policy's requirements) and *Maximum allowed* in the duration picker.
  - CLI: `--hours max`, a DURATION column and a note for capped roles in the activation plan, a MAX
    column in `list`; `list --json` adds `maxDuration` and `policy`; `activate --json` adds
    `duration`, `maxDuration` and `capped` per result plus `duration`, `preset` and `missing`.
- `pimento`, a standalone command-line tool (its own binary, Foundation only, no AppKit/SwiftUI):
  - `pimento list [FILTER…] [--role NAME] [--active|--eligible]`, `pimento status` (active roles,
    soonest-expiring first, time left), `pimento tenants`, `pimento version`, `pimento help [COMMAND]`.
  - `pimento activate (FILTER… | --role NAME | --all) -j TEXT [--hours N] [--yes] [--dry-run]
    [--max-parallel N]` activates for real through the same code as the app. It needs an explicit
    selection, shows the plan with Owner roles highlighted, asks on a terminal, refuses without
    `--yes` when stdin is not one, and sends nothing with `--dry-run` (GET-only transport).
  - `--json` on list, activate, status and tenants; exit codes 0 ok, 1 failed, 2 usage error,
    3 az missing / not signed in / token rejected.
  - Tables fit the terminal and use colour only on a TTY without `NO_COLOR`; piped, plain columns.
  - `pimento completions zsh|bash|fish`.
  - `--role` matches the whole role name (`*` as wildcard), so `--role owner` no longer also picks
    "Storage Blob Data Owner"; a FILTER starting with `/` matches an ARM scope and below.
- **Pimento › Install Command Line Tool…** links the bundled CLI into `/usr/local/bin` (administrator
  prompt) or `~/.local/bin` (no password); **Uninstall Command Line Tool…** removes only Pimento's links.
- Two downloads per release: `Pimento-<version>.zip` (app with the CLI inside) and
  `pimento-cli-<version>-macos.tar.gz` (universal CLI with completions, LICENSE, README), plus
  `SHA256SUMS.txt`. `scripts/package-cli.sh` builds the CLI archive; CI builds and checks both.
- Homebrew formula (CLI) and cask (app) templates in `packaging/homebrew/`, not published yet.
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
- Themes (Settings › General › Appearance), applied live to the main window, its sheets, the
  tenant picker and Settings: Native (default, unchanged), Azure-style (light and dark) and
  Windows XP-style (always light). Styling only; controls and shortcuts are the same. Uses Segoe UI
  or Tahoma only if installed; no Microsoft fonts or artwork are bundled, and Pimento is not
  affiliated with Microsoft.
- Appearance mode (Settings › General › Appearance): System (default), Light or Dark, applied
  live to every window, sheet and popover. Windows XP-style stays light-only; the stored choice
  comes back when switching to another theme.
- Settings › Notifications says whether macOS actually shows banners ("Allowed, but banners are
  off" when the banner style is None or alerts are disabled, with a link to System Settings), and
  *Send Test Notification* reports "Sent ✓ at HH:mm" or the reason macOS refused it.

### Changed

- The app binary is `Pimento.app/Contents/MacOS/Pimento` (SwiftPM product `PimentoApp`:
  `swift run PimentoApp`); the CLI is `Contents/Helpers/pimento` (`swift run pimento`). The app itself
  only reads `--tenant` from its arguments.
- **Activate** always sends for real; the dry-run mode switch is gone. **Preview** (⌥⌘↩, also in the
  View menu) shows the requests without sending them. The Owner confirmation is unchanged.
- The tenant picker in the toolbar no longer looks disabled.
- Azure-style and Windows XP-style colour the window's title bar and toolbar as one bar (near-black
  for Azure, glossy blue for XP) instead of adding a second title strip below the toolbar; the
  title and role counts appear once, in the toolbar.
- Tenant names come from ARM's `GET /tenants` first, so tenants without a subscription show their
  name instead of a bare GUID (`--tenants` too). Tenants nobody names read "Unnamed tenant" plus a
  short ID and sort last.
- Long resource, role and group names are truncated with a tooltip instead of wrapping.
- With "Load roles on launch" off, the window says so and offers Refresh instead of a spinner.

### Deprecated

- `pimento --list`, `--dry-run` and `--tenants` (0.1.0) still work, print a note, and will be removed
  in the next release: use `pimento list`, `pimento activate --dry-run` and `pimento tenants`. Given to
  the app binary, they are handed to the bundled CLI.

### Fixed

- A role activated from the app showed "Eligible" until the next manual refresh, because
  Azure lists a new activation only after a few seconds. It now shows as active right away
  (with the expiry Azure returned), leaves the selection, and the list is re-checked 20 s
  later.
- The test notification could fail silently: errors from macOS are now shown and logged, each test
  gets its own identifier (repeated tests are no longer merged), notifications set
  `interruptionLevel = .active`, and the foreground delegate is in place before the first one.
- `scripts/bundle.sh --install` moves the app to `~/Applications` (unregistering and removing the
  `build/` copy) and registers the installed one, so two copies with the same bundle ID no longer
  compete for notifications.
- Windows XP-style under a dark system: the toolbar stayed dark above the light window. Light and
  dark are now set app-wide instead of per window, so switching themes or modes never leaves a
  window stuck in a forced appearance.

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
