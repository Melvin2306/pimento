# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Pimento sign-in**: sign in without the Azure CLI, with your own public-client app registration
  in Microsoft Entra ID (README › *Pimento sign-in* has the exact registration steps; Pimento ships
  no client ID and does not use Microsoft's). No packages: OAuth 2.0 with URLSession and the Security
  framework.
  - Flows: authorization code with PKCE (S256), `state` and `nonce`, the redirect received by a
    one-shot listener on `http://localhost:<random port>` (127.0.0.1 and ::1; answers *You can close
    this tab*; 5-minute timeout); and the device code flow for SSH and headless use, polling with
    `authorization_pending`, `slow_down` and expiry handled. Scopes
    `https://management.azure.com/user_impersonation offline_access openid profile`.
  - Tokens: the refresh token in the Keychain (generic password, service
    `io.github.melvin2306.pimento`, one item per account, after first unlock, this device only; the
    account info in the item's attributes, so listing reads no secret), shared by the app and the
    CLI; on other systems or with `PIMENTO_TOKEN_STORE=file`, `~/.config/pimento/tokens.json`
    (mode 600, less secure; `%APPDATA%\Pimento\tokens.json` on Windows). Access tokens stay in memory, per account and tenant, renewed five
    minutes before `expires_in` runs out. Rotated refresh tokens are kept. Other tenants get tokens
    by redeeming the refresh token there, so the tenant picker works without signing in again.
  - Errors: `invalid_grant` / `interaction_required` ask you to sign in again; common AADSTS codes
    (MFA, Conditional Access, unknown client ID, redirect URI, public client flows off, consent,
    expired or revoked sessions, clock) in plain words; a claims challenge (from the token endpoint,
    or from an activation that needs an authentication context) is sent with the next browser
    sign-in.
  - Only `login.microsoftonline.com`'s token and device-code endpoints receive sign-in data (a
    transport guard refuses anything else); access tokens still go only to `management.azure.com`.
- **Settings › Account**: auth source (*Azure CLI*, the default, or *Pimento sign-in*), the client
  ID (checked as a GUID), signed-in accounts with *Use* and *Sign Out* (*Sign Out All*), *Sign In…*
  (browser) and *Sign In with Code…* (a sheet with the code, *Copy Code* and *Open Page*). When you
  are signed out, the main window offers both the `az login` command and Pimento sign-in.
- **CLI**: `pimento login [--device-code] [--client-id ID] [--tenant ID]`, `pimento logout [--all]`,
  `pimento whoami [--json]`; every command takes `--auth az|pimento`. The source is `--auth`, then
  `$PIMENTO_AUTH`, then the setting shared with the app (`auth.json`), then the Azure CLI; the client
  ID `--client-id`, `$PIMENTO_CLIENT_ID`, then the saved one. Sign-in problems exit 3 with the
  `pimento login` command that fixes them. Completions and help cover the new commands.

- Menu bar extra (Settings › General › Menu bar › *Show in menu bar*, on by default): a template
  shield-and-arrow glyph drawn by `scripts/make-icon.swift`, followed by the number of active roles and,
  with *Show remaining time in menu bar* (off by default), the soonest end (`1:24`, or `2 · 1:24`).
  - Popover: active roles soonest first (one per scope + role), each with a live countdown (`1:24:05`;
    warning colour within the expiry-reminder lead time) and **Renew** / **End Now**, which confirm inline
    with the main window's texts (now shared in `ConfirmationText.swift`); **Presets** with one-click
    **Activate** (the preset's justification, or an inline field; the Owner confirmation still applies;
    always now); **Scheduled (N)** and **Approvals (N)** links and the count awaiting approval; **Open
    Pimento**, **Refresh**, **Settings…**, **Quit**. Follows the theme and mode (Native, Azure-style,
    Windows XP-style, ultra dark).
  - One timer for every countdown: each second while the popover is open, otherwise only when the menu
    bar text changes (at most about once a minute), none without active roles. Refresh as in the app.
  - Closing the last window keeps Pimento running while the menu bar extra is shown.
  - *Hide Dock icon (menu bar only)* (off by default; only with the menu bar extra): accessory activation
    policy, applied live and at launch.
  - *Launch at login* via `SMAppService.mainApp`, with the login item's state (needs approval in
    System Settings, not a bundled app) and the system's reason when macOS refuses (as it may for
    ad-hoc signed builds).

- Appearance mode **Ultra dark** (Settings › General › Appearance): the dark appearance with pure black
  window, page, table, sheet and Settings backgrounds for the Native and Azure-style themes (OLED).
  Near-black surfaces and bottom bar (`#0A0A0A`), `#1F1F1F` borders, accent-coloured checked rows, a
  black title bar and toolbar; text contrast stays at WCAG AA or better. Windows XP-style stays light.
- Appearance mode **By time of day**: *Light from* (07:00), *Dark from* (19:00) and an optional
  *Ultra dark from* (23:00, off by default), applied live at those times and re-checked after sleep and
  clock or time-zone changes. Settings shows *Now: Dark until 23:00*. Rules: periods wrap across
  midnight; ultra dark runs from its time until light; an ultra dark time inside the light period
  starts with dark; equal light and dark times mean dark all day. Stored as a versioned dictionary
  (`general.appearanceSchedule`), read leniently (bad fields fall back to their defaults). No location
  access. Windows XP-style resolves to light.

- Activation history: a local log of every request Pimento sends, from the app and the CLI
  (activate, schedule, cancel, deactivate, renew, extend, approve, deny): time, tenant (ID and name
  when known), scope and resource, role, outcome (succeeded/pending/skipped/failed with Azure's
  status or error code and a short message), requested and effective duration, start, justification,
  ticket, request ID, source and Pimento version. No tokens, no request or response bodies. One entry
  per role (a renewal is one entry however many attempts); previews and dry runs record nothing.
  - File: `~/Library/Application Support/Pimento/history.jsonl` (`PIMENTO_HISTORY` overrides it),
    JSON Lines, mode 600, shared by the app and the CLI. Appends take an exclusive `flock` and write
    each line with one `write` on an `O_APPEND` descriptor; a line cut off by a crash does not swallow
    the next. Past 5 MB it rotates to `history.1.jsonl`. Settings in `history-settings.json`
    (recording on by default; retention 30/90/365 days or forever, 1 year by default). Lenient reading:
    unknown fields are ignored, unreadable lines skipped.
  - App: **History…** (⇧⌘H, toolbar and View menu): a sortable table with search, period (presets or a
    custom range), action, outcome and tenant filters, relative times, **Export CSV…** (save panel,
    the rows shown), **Import from Azure**, and a row menu with **Activate Again** (checks the role and
    fills in justification, ticket and duration) and **Copy Request ID**. **Settings › History**:
    on/off, retention, Show in Finder, Clear History… (asks first).
  - CLI: `pimento history [WORD…] [--since WHEN] [--until WHEN] [--action …] [--outcome …] [--tenant ID|NAME]
    [--limit N] [--json | --csv]`, `pimento history export FILE.csv` (`-` for stdout),
    `pimento history import-azure [--since WHEN]` and `pimento history clear [--yes]` (exit 2 without
    `--yes` when stdin is not a terminal). `--since`/`--until` take `7d`, `24h`, `today`, a date, a
    date and time, or ISO 8601.
  - CSV: RFC 4180 (header row, CRLF, UTF-8, quoting), ISO 8601 UTC times plus a local-time column;
    fields starting with `=`, `+`, `-`, `@`, tab or CR get a leading `'` (formula injection guard).
  - Import from Azure reads your own requests (`roleAssignmentScheduleRequests`, `asTarget()`,
    read-only), keeps your self-service ones and adds those whose request ID the history does not
    have yet, as source `azure`.

- Approval workflow (Azure-resource PIM).
  - Requester: an activation that needs approval (`PendingApproval`) shows *Awaiting approval*
    (app) / `awaiting approval … (request 7a1b2c3d)` with a note and exit code 0 (CLI), gets no expiry
    reminder, and is listed under Scheduled with when it was asked and when it expires (24 hours).
    The app follows such requests, reads `roleAssignmentScheduleRequests` (`asTarget()`) every
    minute while any wait (not when auto-refresh runs every minute; paused during an activation),
    and notifies when one is approved (with the expiry, plus expiry reminders), denied (with the
    approver's justification and name when readable), expired or cancelled.
  - CLI: `pimento pending [--json]` (age, expiry); `pimento wait (REQUEST-ID… | --all) [--timeout 30m]`
    polls every 30 s until decided: exit 0 approved, 1 denied/expired/cancelled/not found, 4 timeout
    (new exit code). `activate --json` adds `requestId` to submitted results; `scheduled --json` adds `expiresAt`.
  - Approver: **Approvals (N)** in the toolbar and *Approvals…* (⇧⌘P) list the requests you may
    decide (`roleAssignmentScheduleRequests` `asApprover()` joined with `roleAssignmentApprovals`
    `asApprover()`, 2021-01-01-preview): requester, role, scope, duration and start, justification,
    ticket, age, expiry. Multi-select, a required justification, Approve and Deny (Deny always asks,
    Approve asks for Owner roles), per-row results. A refused or empty listing reads "You have no
    approvals to review".
  - CLI: `pimento approvals [--json]`, `pimento approve ID… -j TEXT` and `pimento deny ID… -j TEXT`
    (`--yes`, `--dry-run` on a GET-only transport, TTY prompt, Owner warning), sending
    `PATCH …/roleAssignmentApprovals/{id}/stages/{stage}` with `{reviewResult, justification}`.
  - Settings › Notifications: *Approval decisions* and *New approval requests* (both on); a new-request
    notification opens the Approvals sheet.
  - Errors in the `{"Message": …}` shape of the approvals endpoints are read like ARM's usual ones.

- Scheduled activation: a `SelfActivate` with a later `scheduleInfo.startDateTime`. PIM answers
  `Granted` and activates the role at the start; it accepts a start up to a month ahead
  (`ScheduleStartTimeTooFarAhead` beyond), also while the role is still active.
  - App: a **Start** menu in the bottom bar (Now, In 1 hour, Tomorrow 08:00, Next working day 08:00,
    Pick Date and Time…, local time, up to 30 days); the button reads *Schedule N roles* and results
    *Scheduled for Fri 08:00*. A **Scheduled** view (toolbar, ⇧⌘L) lists your scheduled activations
    and requests awaiting approval from Azure (`roleAssignmentScheduleRequests`, `asTarget()`), with
    Cancel and Cancel All (`POST …/cancel`; `RequestCannotBeCancelled` is reported). Rows with a
    pending request show a *Scheduled* / *Awaiting approval* badge. Optional local notification when
    a scheduled activation starts (Settings › Notifications, on by default), rebuilt whenever the list
    is read.
  - CLI: `pimento activate … --at WHEN` (`now`, `+1h30m`, `08:00`, `today 17:00`, `tomorrow 08:00`,
    `mon 08:00`, `workday 08:00`, `2026-11-02 08:00`, ISO 8601 with a zone); a bad, past or too
    distant start is a usage error (exit 2) before anything is sent. Active roles that end by the
    start are scheduled, ones still active then are skipped. `--json` adds `start` and a `scheduled`
    outcome and count. `pimento scheduled [--json]` lists pending activations;
    `pimento cancel (REQUEST-ID… | FILTER… | --role | --all) [--yes] [--dry-run] [--json]` cancels them.
- Ticket information (`ticketInfo {ticketNumber, ticketSystem}`).
  - Roles whose policy requires a ticket (`Ticketing` in `Enablement_EndUser_Assignment`) are marked
    *needs ticket*; checking one shows ticket number and system fields, and activating waits until
    both are filled in. Any activation can carry a ticket (ticket button). The last ticket system is
    remembered and recent tickets are offered like recent justifications.
  - CLI: `pimento activate --ticket NUMBER [--ticket-system NAME]`; a role that needs a ticket
    without number and system stops `activate` with exit 2, naming the roles.
  - Presets can store a default ticket system (Manage Presets, `presets save --ticket-system`).
  - A `TicketingRule` policy failure now reads "a ticket is required: give a ticket number and
    ticket system".

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
- **The CLI on Linux and Windows.** `pimento` and the core build and pass their tests on Linux
  (Swift 6, x86_64 and arm64) and Windows (Swift 6, x86_64); `Package.swift` declares the app only on
  macOS. CI has `Linux` and `Windows` jobs next to `macOS`, and releases add
  `pimento-cli-<version>-linux-x86_64.tar.gz` (`-linux-aarch64` once the repository is public) and
  `pimento-cli-<version>-windows-x86_64.zip` (Swift runtime linked in on Linux, its DLLs included on
  Windows), listed in `SHA256SUMS.txt`.
  `scripts/package-cli.sh` packs the archive of the platform it runs on.
  - Files: `$XDG_CONFIG_HOME/pimento` (else `~/.config/pimento`) on Linux, `%APPDATA%\Pimento` on
    Windows, for presets, history, `auth.json` and the token file (macOS is unchanged).
  - `az`: `PATH` on Linux; `az.cmd` (`Path`, `;`-separated) on Windows, where the installer's
    Python runs it directly and another batch file goes through `cmd.exe` only with plain arguments.
  - History: `LockFileEx` on `history.jsonl.lock` on Windows instead of `flock`; no POSIX modes there.
  - Windows has no browser sign-in yet: `pimento login` says so and uses a device code. The console
    gets UTF-8 output and ANSI colours where it supports them (else none).
  - Linux opens the browser with `xdg-open` from `PATH`.
- Homebrew, ready to publish (not published): `packaging/homebrew/` has a formula (the CLI from the
  release archives on macOS 14+ and Linux, with completions) and a cask (the app, its CLI linked as
  `pimento`, `zap` of Pimento's folders, a Keychain caveat), both passing `brew style`.
  `scripts/update-homebrew.sh VERSION [--release | --from DIR]` fills in the version and sums and
  writes `build/homebrew/`; `packaging/homebrew/README.md` explains the tap and its checks.
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

- **Settings window redesigned**: wider (800 pt) and compact, so no pane needs scrolling. Each
  pane lays its options out in two columns of grouped cards with right-aligned labels; simple
  on/off options are checkboxes instead of switches; long explanations moved into ⓘ buttons
  (tooltip on hover, popover on click). A new **Appearance** pane picks the theme from cards with
  a small preview of each, the mode from a segmented control (the time-of-day times in one row),
  and the table columns as one row of checkboxes. Every option, its default and where it is
  stored are unchanged.
- The `az not found` error names the install command of the platform (`brew`, Microsoft's Linux
  packages, `winget`). An HTTP error without a body reads the same on every platform ("forbidden").
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

- The app could stop with "No Observable object of type AppModel found" when the search filter removed
  rows from the role table: the Duration cell read the model from the environment, which SwiftUI does
  not always provide to a cell that is leaving the table. It now gets the model directly.
- Renew sends ticket information again: the ticket the current activation was requested with
  (found through your requests), or the ticket fields / `pimento renew --ticket NUMBER
  [--ticket-system NAME]`. A role whose policy requires a ticket is skipped with a reason when no
  ticket is known, instead of failing with `TicketingRule` after it was already ended. Roles whose
  policy requires approval are still not renewed.
- A role submitted for approval was counted as activated in the completion notification and got an
  expiry reminder; it now reads "awaiting approval".
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
- Activate and Renew could be sent twice: a second click, ⌘↩, a preset or a reminder action while
  the role policies were still loading started the same operation again. The values sent are now
  the ones on screen when the button was pressed.
- Expiry reminder actions: a tap right after launch, or while a refresh ran, could refuse the
  current tenant or say the roles were no longer active (and withdraw their reminders). Renew from
  a reminder without a stored justification now asks instead of using the main window's text, and
  the notification delegate is set before launch finishes so a tap that launches the app is not lost.
- Two batches expiring in the same minute (or in two tenants) kept only one expiry reminder.
- A renewal that ends up waiting for approval is reported as such, not as "0 renewed".
- A request ARM accepts with a failure status (`Failed`, `FailedAsResourceIsLocked`, `Denied`, …)
  counts as failed, not as submitted or scheduled.
- Approving or denying when the approval's stages cannot be read reports the error instead of
  "not pending any more".
- Signing out while a token refresh was running could bring the account back with the rotated
  refresh token; a sign-out that cannot delete `tokens.json` now fails instead of reporting success.
- The bearer token follows ARM `nextLink` pages only over HTTPS.
- Presets, history settings and CSV exports are mode 600 from the moment they are created, and the
  data folder is created 700.
- History pruning keeps lines it cannot read; `pimento history --until DAY` includes that day.
- CLI: a closed output pipe (`pimento … | head`) ends quietly instead of crashing; a huge
  `wait --timeout` is refused instead of crashing; `pimento --help COMMAND` shows that command;
  `-j -y` no longer takes `-y` as the justification; `--ticket-system` needs `--ticket`; `tenants`
  honours `$PIMENTO_TENANT`; help, presets, history and `logout` work with an invalid
  `$PIMENTO_AUTH`; `login` and `logout` warn when `auth.json` cannot be written; an `az` crash is
  no longer reported as a 90-second timeout.
- App: account switches and sign-outs wait for a running operation; Activate Again no longer keeps
  a ticket or justification from other requests; Cancel All says it also withdraws requests awaiting
  approval; a failed Renew or Deactivate keeps Azure's MFA claims challenge for the next sign-in.
- "Install Command Line Tool…" checks again, as administrator, that it replaces or removes only a
  symlink.
- Release workflow: only the publishing job gets a write token.
- HTTP redirects are no longer followed, for ARM and for sign-in: the host checks covered only the
  first URL. A redirect is now an error.
- A renewal whose re-activation answer was lost (a timeout) could end as "ReactivationFailed"
  while the role was active again: PIM then answers `RoleAssignmentExists` to every later attempt.
  After a lost answer the role's activations are read, and the renewal reported when it went
  through.
- Deactivate sends the eligibility the activation was made with (its `linkedRoleEligibilityScheduleId`),
  not the row's: for a role held both directly and through a group they can differ. When it is
  not known yet, it is read before sending.
- Presets and `tokens.json` are locked while they are changed (`flock`, `LockFileEx` on Windows), so
  the app and the CLI saving at the same moment no longer lose an update.
- Dates are parsed and formatted with shared formatters instead of new ones each time.
- The sign-in redirect listener gives each connection 5 seconds in all: a local client sending a
  byte at a time can no longer hold it.
- An `az` that times out is ended with everything it started (its process group; the process tree
  on Windows): a Python child holding the output open could keep Pimento waiting past 90 seconds.
- Sign Out All also removes Keychain items whose account info cannot be read.
- `pimento deactivate`, `renew` and `extend` name the auth source's default tenant ("your sign-in
  tenant" with Pimento sign-in) instead of always "az's default tenant".
- A browser sign-in whose id token lacks the nonce is refused (before, only a different nonce was).
- `pimento tenants` with no tenants exits 0 in the table too (with a note on stderr), as it did with
  `--json`.
- CI and release workflows pin third-party actions to commit SHAs; tests clean up their temporary
  files.
- An `az` that timed out while not leading its own process group (or was already reaped) made
  Pimento call itself forever and crash; it is now simply terminated.

### Security

- `pimento approve|deny --yes` takes only whole request ids (36 characters) and matches them
  exactly. Before, a prefix was resolved again when the command ran, so a requester who cancelled a
  reviewed request and submitted another under the same prefix (for example for Owner) could have it
  decided without the approver seeing it. On a terminal a prefix still works: the prompt shows the
  request it matched. `pimento approvals` and the decision table show the whole id.
- `pimento login` no longer passes the sign-in URL (with its `state`, `nonce` and PKCE challenge) as
  a process argument, where other local users can read it (`/proc/PID/cmdline` on Linux) and could
  answer the loopback redirect with a code for their own account. macOS opens it through
  LaunchServices without a child process; Linux runs `xdg-open` on a private redirect page (mode 600
  in a new 700 folder in the temporary directory), removed when the sign-in is over.
- The CLI shows text that comes from others (a requester's justification and ticket, role, resource,
  group and tenant names, Azure's error messages, an approver's reason) with control characters, escape
  sequences and bidi overrides as visible escapes (`\r`, `\e`, `\u{202E}`). Before, a carriage return
  in a justification could overwrite the row shown just before `approve`'s `[y/N]`, and escape
  sequences could hide text, set the clipboard or fake links. `--json` keeps the exact values (DEL, C1
  and bidi characters are now written as `\uXXXX`); CSV on stdout is exact when piped.
- The sign-in listener for `http://localhost:<port>` holds both 127.0.0.1 and ::1 on its port, or
  none: when another program (another local user, for example) already listens on ::1 at that port,
  Pimento tries another port (16 in all) and otherwise fails, instead of listening on 127.0.0.1 alone
  while a browser that tries ::1 first sends the code and `state` to the other program. IPv4 alone is
  used only where the system has no IPv6 loopback. The redirect URI stays `http://localhost`: Entra
  documents the ignored port only for `localhost`, and `http://127.0.0.1` needs a manifest edit.
- The expiry reminder's **Renew** and **End Now** actions require an unlocked Mac
  (`authenticationRequired`): someone at the locked screen can no longer end (or renew) your roles
  from the notification. End Now on an Owner role brings the app forward and asks first, as the
  app's own Deactivate does.
- The history CSV quotes every field and puts the formula guard (`'`) also after each `;` or tab
  inside a field: a ticket number such as `INC1;=1+1;` from a requester no longer becomes a formula
  cell in a spreadsheet that splits on `;` (the list separator of many locales).
- Signing out in one Pimento process (`pimento logout`, or the app) can no longer be undone by a
  token refresh in flight in another: the rotated refresh token replaces the stored one only while
  it is still the one redeemed (under the file lock; Keychain items are only updated, never
  re-created), so a removed account stays removed and a newer sign-in keeps its token.
- Renew (app and `pimento renew`) skips a role whose policy could not be read (`PolicyUnknown`)
  instead of treating it as "no approval needed": before, a failed policy read let renew end a role
  that then waited for an approver to come back.
- Activation, deactivation, renewal and extension URLs percent-encode the scope (as cancel already
  did, now with an ASCII-only allowlist): a `?`, `#` or space in a scope can no longer cut the `PUT`
  path short. A scope that cannot be a path (`..`, empty segments) is an error instead of a crash.
- A preset's tenant is checked like `--tenant` (a GUID or a domain, not starting with `-`) before
  the CLI uses it, and so before it reaches `az --tenant`; the presets file can be edited by hand.
- Resource filters and `--role` names are trimmed, and one that is empty after trimming is a usage
  error: `pimento deactivate " " --yes` ended a role, as a space is part of most resource names.
- Lock files, the history file and private files are opened without following symbolic links
  (`O_NOFOLLOW`; reparse points are refused on Windows), a lock file must be a regular file, the
  history's identity check uses `lstat`, and the mode of a private file is set on its descriptor
  before the rename instead of by path afterwards.
- The app loads roles, policies, requests, approvals and Azure history, and builds previews, through
  a GET-only transport (`PIMService.readOnly`), as the CLI does and as SECURITY.md says; only
  activate, deactivate, renew, cancel and approve/deny use the writable one.

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
