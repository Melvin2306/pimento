# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-31

AI agents, keep alive and an update check; Raycast and Alfred launchers; browser sign-in and
PowerShell completions on Windows; tenant badges.

### Added

#### AI agents (MCP)

- **`pimento mcp`**: a Model Context Protocol server on stdin/stdout, so AI agents (Claude Code,
  Claude Desktop, Cursor, …) can work with your PIM roles. Speaks the stateless 2026-07-28 revision
  and the `initialize`-based revisions 2024-11-05 to 2025-11-25, without new dependencies, on
  macOS, Linux and Windows. See README › AI agents (MCP).
- **Read-only by default**: `list_tenants`, `list_eligible_roles` (with each role's policy),
  `list_active_roles`, `list_presets`, `list_pending_approvals` and `get_history`.
- **Writes only with `--allow-activate`**: `activate_roles`, `deactivate_roles` and `renew_roles`.
  Each request is planned read-only, shown to you through MCP elicitation and sent only after you
  confirm it; clients without elicitation cannot write unless the server runs with `--no-confirm`.
  Owner, User Access Administrator and Role Based Access Control Administrator also need
  `--allow-privileged` and a second confirmation. A confirmation is bound to the signed-in account,
  so one given before a switch of account is not used after it, and it names the roles that a
  keep-alive preset will renew beyond the duration shown.
- Durations are capped at the policy maximum, a justification is required, arguments are
  validated strictly, and every write is recorded in the history (source `mcp`). Results and error
  messages never contain tokens or file paths: a path is redacted whole, also when a folder name
  has spaces (`Application Support`, a user name). Finished requests are not kept for the rest of
  the session.
- `--tenant` (or `PIMENTO_MCP_TENANT`) keeps the server in one tenant, and `list_tenants` then lists
  only that tenant; `--demo` runs it on the demo data.

#### Keep alive

- **Keep alive** in the app: mark active roles (right-click › *Keep Alive*) or a preset (*Keep
  alive* in Manage Presets), and Pimento renews them shortly before they expire, during working
  hours (Settings › Activation › Keep alive: days and hours, Mon–Fri 08:00–18:00 by default, local
  time). Works in demo mode.
- **No gap**: fifteen minutes before the end, Pimento schedules the next activation to start exactly
  when the current one ends (PIM has no self-service extension; `SelfExtend` / `SelfRenew` need an
  administrator).
- **The rules**: the policy maximum and working hours apply (the last renewal of the day is
  shortened to whole hours ending by then, or skipped). The justification and ticket of the
  activation are reused, and a renewal whose policy needs one that is unknown is skipped with a
  notification. Roles needing approval are never renewed (the UI says why). A role ended early
  (noticed from the listing and from your requests, also after sleep or a restart) is not brought
  back and its continuation is withdrawn, as on pause. One that lapsed while the Mac slept is
  activated again on wake if still inside working hours. Failures back off (1, 5, 15 minutes) and
  stop after 4 per role per window.
- A status icon and tooltip in the table and the menu bar, a *Keep Alive* toolbar menu, and a
  global *Pause* (toolbar, menu bar, Settings). Notifications follow the completion settings
  (*Renewed Contributor until 18:00*, and failures).
- Keeping a role alive that can grant access (Owner, User Access Administrator, RBAC Administrator)
  asks once when it is marked (per role or through a preset), while *Confirm before activating
  Owner roles* is on.
- Switching tenant or account while a keep-alive pass waits for Azure stops that pass, so it cannot
  write the previous session's state (ends, continuations, justifications) into the new one, where
  the next pass could withdraw the old session's continuations with the new token or reuse a
  justification. The app runs a new pass a few seconds later.
- **`pimento keep-alive`**: the same rules as a foreground loop until Ctrl-C, for Linux, Windows and
  servers (`--days`, `--window`, `--hours`, `-j`, `--preset`, `--dry-run`). It asks at its prompt,
  or takes `--yes`, as `activate` does. The scheduler lives in PimentoCore (`KeepAlive`,
  `KeepAliveSession`), shared by the app and the CLI.
- Presets have an optional `keepAlive` field.
- History: a new source, **Keep alive** (`keepAlive` in the file, CSV and JSON), for everything
  keep-alive sends.

#### Update check

- Once a day (at launch, or while running) the app asks GitHub for the latest release and, when it
  is newer, shows a one-line notice above the role table and in the menu bar with *Download* (the
  release's disk image) and *Release Notes*; the ✕ hides it until the next version.
- **Pimento › Check for Updates…** checks now; *Settings › General › Updates* has the switch (on by
  default), *Check Now* and the last result.
- `pimento version --check [--json]` prints the current and latest versions and how to update
  (re-run the installer); no other CLI command contacts GitHub.
- Versions are compared as semantic versions; drafts and pre-releases are ignored. Nothing is
  downloaded or installed automatically. `PIMENTO_NO_UPDATE_CHECK=1` turns it off in the app and the
  CLI, and demo mode never checks.

#### Raycast and Alfred

- **Raycast extension** (`integrations/raycast`): *Search PIM Roles* (status, activate with a
  justification, duration and, when the policy asks, a ticket; deactivate), *Activate PIM Preset*
  and *Active PIM Roles* with the time left. It runs the installed `pimento` with an argument list
  (`execFile`, no shell), finds it in a preference, `~/.local/bin`, `PATH` or `Pimento.app`, shows
  the CLI's errors by exit code, and has a demo mode preference. Not in the Raycast Store: install
  it with `npm ci && npm run dev`.
- **Alfred workflow** (`integrations/alfred`): the `pim` Script Filter lists presets, active roles
  (time left) and eligible roles from the CLI's JSON; ↩ activates a role (after `>` and a
  justification) or a preset, ⌥↩ deactivates. POSIX `sh` and JXA only. `build.sh` packs
  `build/Pimento.alfredworkflow`; `test.sh` runs the scripts against `pimento --demo` (also in CI).
- Both activate a preset by its id (`--preset-id`), so the preset you picked is the one that runs.
  Passing its name would leave the choice to the CLI, which can differ from the launcher's (a
  preset whose tenant is a domain, or names that only Unicode case folding makes equal), so
  `--yes` could run a same-named preset of another tenant.

#### Command line

- **`--id ID`** for `pimento list`, `activate`, `deactivate` and `renew`: exactly the role whose
  `id` or `eligibilityScheduleId` in `list --json` is ID (repeatable). For scripts and launchers
  that picked one row, where a scope filter would also match the roles below that scope.
- **`pimento activate --preset-id ID`**: exactly the preset whose `id` in `presets list --json` is
  ID, in its own tenant.
- `pimento list --json` has a `grantsAccess` field: true for Owner, User Access Administrator and
  Role Based Access Control Administrator.
- **Browser sign-in on Windows.** `pimento login` opens the browser there too (authorization code
  with PKCE), instead of always using a device code; `--device-code` still works. The loopback
  listener now runs on Winsock with the same code as on macOS and Linux: loopback only (127.0.0.1
  and ::1 on one port, another port when a program holds the ::1 side), the `state` check, the
  per-connection and overall timeouts, and one answer. On Windows its port is held with
  `SO_EXCLUSIVEADDRUSE`, so no other program can bind it, even with `SO_REUSEADDR`. The browser is
  opened with `ShellExecuteW` on a private redirect page; the URL is never in a command line.
- **PowerShell completions.** `pimento completions powershell` (or `pwsh`) prints a
  `Register-ArgumentCompleter` script for Windows PowerShell 5.1 and PowerShell 7. It completes
  commands, flags, their fixed values, the words after `presets`, `history`, `completions` and
  `help`, and the names of your presets (read with `pimento presets list --json`, offline). A typed
  `--tenant` is passed on to `pimento presets list` only when it is a GUID or domain, in one
  argument (Windows PowerShell 5.1 would split a value with a double quote). cmd.exe has no
  programmable completion, so it gets none.
- The Windows zip ships the completions as `completions\pimento.ps1`, and `install.ps1` loads them
  from a marked block in your PowerShell profile. The block is replaced, not repeated, on every
  install, and `-Uninstall` removes it; the rest of the profile, and its encoding, stay as they
  were. `-NoCompletions` (`PIMENTO_NO_COMPLETIONS=1`) skips it, and `-ProfilePath`
  (`PIMENTO_PROFILE`) picks another profile.

#### Tenant badges and logos

- **Tenant badges**: the tenant picker, the toolbar, the menu bar and the tenant menus of Settings
  and History show each tenant as one or two initials on a colour from its tenant ID (*Northwind
  Traders* → *NT*; legal forms such as *SE*, *GmbH* or *Inc.* skipped; the domain for unnamed
  tenants) instead of a building symbol. Drawn offline; the palette keeps white initials at WCAG AA
  and stays visible in light, dark, ultra dark and the Azure and XP themes.
- **Fetch tenant logos** (*Settings › General*, off by default): shows the square logo of a
  tenant's Microsoft sign-in page, else its website's icon, instead of the initials. Unauthenticated
  and without cookies, Microsoft's branding CDNs only for the sign-in logo, HTTPS, 512 KB and
  image checks, cached for 7 days with *Refresh Logos* and *Clear Cache*; never in demo mode. It
  tells Microsoft and each tenant's website that this Mac looked them up (see *Security and privacy*).

### Changed

- `pimento activate --preset NAME --tenant DOMAIN` (and `deactivate`, `renew`, `keep-alive` and
  MCP) prefers a preset saved for that domain over one saved for any tenant.
- `pimento activate` and `renew` plan their requests with the same code as `pimento mcp`
  (`ActivationPlanning`); their behaviour is unchanged.
- Sign-in connections end with a lingering close (no more sending, the rest of the request read,
  then closed), so a connection reset cannot discard the answer page before the browser shows it.
- The first builds' deprecated flags (`pimento --list`, `--dry-run`, `--tenants`) still work in
  0.2.x and will be removed in a later release.
- CI runs the loopback listener tests on Windows too, tries the PowerShell completions with
  `TabExpansion2` in both PowerShells, and runs the Raycast extension's tests and type check.

### Fixed

- When another program holds the sign-in port, the error names the way around it:
  `pimento login --device-code`, or *Sign In with Code…* in the app.
- `install.ps1` never takes `.` or `..` from its file list as a file to remove.

### Security

- `pimento mcp` refuses every default-ignorable character in an agent's arguments (justification,
  ticket, preset, role, scope, filters), not only the formatting and zero-width ones: variation
  selectors (U+FE00–U+FE0F, U+E0100–U+E01EF) and similar characters render as nothing and do not
  count as characters, so a justification that read *INC-1234 read the logs* in the confirmation
  could otherwise carry thousands of hidden characters to Azure and the history. An emoji's own
  presentation selector (⚠️, ✔️, 1️⃣) is still accepted, every string is also limited to four
  Unicode scalars per allowed character, and the confirmation shows any invisible character as an
  escape.
- The Raycast extension's preset detail shows the preset, role, scope and rule names, the
  justification and the ticket system as plain text, not as Markdown, so a name from Azure or the
  presets file (`![](https://…)`) cannot load a remote image when the row is selected, or show a
  link.
- The Raycast extension and the Alfred workflow skip a `pimento` that another user could have
  placed or changed when they look for it (the file, after following links, or its folder not
  owned by you or root, or writable by others or by a group other than wheel or admin), as the CLI
  does for `az`, so a `pimento` in a shared, writable folder on the `PATH` is never run.
- The Raycast extension and the Alfred workflow treat User Access Administrator and Role Based
  Access Control Administrator like Owner, from `grantsAccess` in `pimento list --json`: Raycast
  asks once more before activating them, Alfred warns before ↩. A preset's copied command (*Copy
  Command*, Alfred's ⌘C) quotes the name for a shell, so pasting it cannot run what a name like
  `$(…)` contains.
- The update check sends one HTTPS `GET` to `api.github.com` with only `User-Agent:
  Pimento/<version>` and a fixed `Accept-Language: en` (no cookies, tokens or IDs; the same two
  headers as the logo fetch), with a timeout, through a guard that refuses any other URL or method.
  It uses the logo fetch's private session: no stored credentials, and every authentication request
  but the certificate check refused, so no client certificate or password can be offered to a
  server that asks; on macOS its 1 MB limit stops the download as it is reached. The answer is
  untrusted: a strict version parse, a size limit, and links built from the version under
  `https://github.com/Melvin2306/pimento/`, never taken from the answer. `pimento version --check`
  prints an installer command for exactly the version it found. See README › Security and privacy.
- Tenant logos: the largest logo decoded is 1024 pixels on a side (the badge shows 96), so a large
  image cannot take some 64 MB of memory to decode.

## [0.1.0] - 2026-10-30

The first public release. It covers everything built before it; the development history is in
the git log.

### Added

#### Downloads and installation

- **`Pimento.dmg`**: the app (universal: Apple silicon and Intel) with an *Applications* link to
  drag it onto, built by `scripts/make-dmg.sh` (compressed, ad-hoc signed, checked with
  `hdiutil verify`). `Pimento.zip` holds the same app.
- **CLI installers**: `scripts/install.sh` (macOS and Linux, POSIX `sh`:
  `curl -fsSL …/install.sh | sh`) and `scripts/install.ps1` (Windows: `irm …/install.ps1 | iex`).
  They download the archive for the system from the latest release (or `PIMENTO_VERSION`), check
  its SHA-256 against `SHA256SUMS.txt` and, when the GitHub CLI is signed in, its build provenance
  attestation, and install for the current user without `sudo` or administrator rights:
  `~/.local/bin` plus completions for your shell, or `%LOCALAPPDATA%\Programs\Pimento` added to
  the user PATH. `--uninstall` (`PIMENTO_UNINSTALL=1`) removes them again. CI runs both against
  the packaged CLI on macOS, Linux and Windows, including a tampered archive.
- **Release assets** for macOS, Linux (x86_64; aarch64 when built) and Windows (x86_64), each
  under a stable name (`Pimento.dmg`, `pimento-cli-macos.tar.gz`,
  `pimento-cli-linux-x86_64.tar.gz`, `pimento-cli-windows-x86_64.zip`, …) so that
  `releases/latest/download/<name>` links always work, and with the version in the name. All are
  listed in `SHA256SUMS.txt` and carry GitHub build provenance attestations.
- **Pimento › Install Command Line Tool…** links the bundled CLI into `/usr/local/bin`
  (administrator prompt) or `~/.local/bin`; **Uninstall Command Line Tool…** removes only Pimento's
  links.

#### The app

- **All eligibilities in one table**: every Azure-resource PIM eligibility of the signed-in user
  (management groups, subscriptions, resource groups, resources), direct and group-inherited, with
  ABAC conditions, active state and expiry. Columns can be hidden; long names are truncated with a
  tooltip.
- **Bulk activation** with one justification and duration, in parallel (8 at a time by default,
  1–16), with per-row results and plain-language policy failures (`ExpirationRule`,
  `JustificationRule`, `MfaRule`, …). ABAC conditions are copied into the request. Activated rows
  show as active at once and are re-checked shortly after.
- **Each role's PIM policy** (maximum duration, justification, ticket, MFA, approval,
  authentication context) is read and cached: requests use `min(asked, policy maximum)`, the
  Duration column shows what each role gets, and *Maximum allowed* asks for each role's maximum.
- **Preview** (⌥⌘↩) shows the exact `PUT` URLs and bodies without sending anything; **Activate**
  asks first for *Owner* roles.
- **Ticket information** for roles whose policy requires it (*needs ticket*), on any activation
  if you like; the last ticket system and recent tickets are remembered.
- **Scheduled activation**: a *Start* menu (in 1 hour, tomorrow 08:00, next working day 08:00, any
  time up to 30 days ahead), a **Scheduled** view of pending activations straight from Azure with
  *Cancel* / *Cancel All*, badges on the rows and an optional notification when one starts.
- **End early and renew**: *Deactivate* ends active roles (with PIM's five-minute minimum shown as
  *Too soon*); *Renew* ends and activates them again for a fresh duration, retrying while PIM
  removes the old activation. Roles that need approval are not renewed.
- **Approvals**: requests that need approval show *Awaiting approval* and are followed until
  approved, denied, expired or cancelled, with a notification. As an approver, **Approvals (N)**
  lists the requests you may decide, to approve or deny in bulk with a justification (ARM's preview
  approvals API).
- **Presets**: named sets of roles per tenant with an optional justification, duration and ticket
  system; select or activate them from the toolbar, the menu bar or ⌘1–⌘9, and manage them in a
  sheet. Roles you are no longer eligible for are reported, the rest is activated.
- **History**: every request Pimento sends (app and CLI), with outcome, duration, justification,
  ticket and request ID; no tokens or bodies. A searchable, filterable window (⇧⌘H) with CSV export,
  *Import from Azure* and *Activate Again*; retention and recording under Settings › History.
- **Menu bar extra**: the pepper-shield glyph with the number of active roles (optionally the
  soonest end), a popover with live countdowns, **Renew** / **End Now**, one-click presets and links
  to Scheduled and Approvals. Pimento keeps running there when the window closes, optionally
  without a Dock icon; *Launch at login*.
- **Notifications**: when a batch finishes, and a reminder before activated roles expire (10
  minutes by default) with **Renew** and **End Now** actions.
- **Tenant picker** (⇧⌘T): every tenant by name, searchable, with hidden tenants, manual entry and
  `--tenant` / `PIMENTO_TENANT`.
- **Settings** (⌘,): Account, General, Activation, Notifications, History and Appearance panes, in
  two columns of grouped cards.
- **Themes** and modes: Native, Azure-style and Windows XP-style; System, Light, Dark, *Ultra dark*
  (pure black, for OLED) or *By time of day*. Styling only; no Microsoft fonts or artwork are
  bundled.
- **App icon** "Pepper shield" and a matching menu bar glyph, drawn by `scripts/make-icon.swift`.

#### Pimento sign-in

- Sign in **without the Azure CLI**, with your own public-client app registration in Microsoft
  Entra ID (no client secret; Pimento ships no client ID): authorization code with PKCE in the
  browser, or a device code for SSH and headless use. The refresh token is kept in the Keychain
  (elsewhere, or with `PIMENTO_TOKEN_STORE=file`, in a mode-600 `tokens.json`), shared by the app
  and the CLI; other tenants work without signing in again. Settings › Account, or `pimento login`,
  `logout` and `whoami`; `--auth az|pimento` on every command.

#### The `pimento` command line

- A standalone tool (Foundation only) for macOS, **Linux** (x86_64 and arm64, glibc 2.35+, Swift
  runtime linked in) and **Windows** 10/11 (x86_64, Swift runtime DLLs included): `list`, `status`,
  `activate` (`--at`, `--ticket`, `--preset`, `--hours max`, `--dry-run`), `deactivate`, `renew`,
  `extend`, `scheduled`, `cancel`, `pending`, `wait`, `approvals`, `approve`, `deny`, `presets`,
  `history` (`export`, `import-azure`, `clear`), `tenants`, `login`, `logout`, `whoami`, `version`,
  `help` and `completions zsh|bash|fish`.
- Commands that change roles show the plan (Owner roles highlighted), ask `[y/N]` on a terminal
  and need `--yes` otherwise. `--json` output, documented exit codes (0 ok, 1 failed, 2 usage,
  3 not signed in, 4 `wait` timeout), tables that fit the terminal, colour only on a TTY without
  `NO_COLOR`.
- Files in `~/Library/Application Support/Pimento` (macOS), `$XDG_CONFIG_HOME/pimento` (Linux) or
  `%APPDATA%\Pimento` (Windows); on Windows `pimento login` uses a device code.

#### Demo mode

- Every feature against a simulated Azure with synthetic data (Contoso, Fabrikam, … and `.example`
  domains), offline and isolated from your own settings, files, Keychain and sign-in: *Pimento ›
  Demo Mode*, `--demo` or `PIMENTO_DEMO=1`; `pimento --demo <command>`. Activations expire,
  scheduled ones start and a simulated approver decides. A *Demo* menu and `PIMENTO_DEMO_CLOCK`,
  `PIMENTO_DEMO_SPEED` and `PIMENTO_DEMO_BADGE` help with screenshots.

#### Project

- GitHub Actions CI (macOS, Linux, Windows, ShellCheck) and a release workflow; Homebrew formula
  and cask templates in `packaging/homebrew/` (not published yet).

### Security

- **Tokens**: access tokens are fetched on demand, kept in memory only and sent only to
  `management.azure.com`; sign-in data goes only to `login.microsoftonline.com`'s token and
  device-code endpoints (a transport guard refuses anything else). HTTP redirects are not
  followed, and `nextLink` pages only over HTTPS to ARM, without credentials in the URL.
- **Read-only paths**: previews, `--dry-run`, the CLI's read-only commands and the app's reads go
  through a transport that refuses anything but `GET`. Writes are only the
  `roleAssignmentScheduleRequests` `PUT`s, `POST …/cancel` and the approval `PATCH`, after a
  confirmation or `--yes`.
- **Approvals**: `approve|deny --yes` takes only whole request IDs, matched exactly. Approving
  Owner, User Access Administrator or Role Based Access Control Administrator warns (and asks in
  the app). `pimento cancel` treats a hex-only target as a request ID, never as a resource filter.
  Renew skips a role whose policy cannot be read.
- **Sign-in**: PKCE (S256), `state` and `nonce` (a missing nonce is refused); the loopback listener
  holds both 127.0.0.1 and ::1 on its port, serves connections side by side with 5 seconds each and
  closes after one answer or 5 minutes. The sign-in URL is never passed as a process argument (Linux
  opens a private redirect page) and is printed only when no browser opens. Sign-out holds across
  processes, and sign-in never falls back to another account.
- **Terminal output**: text from Azure, Entra or other people (justifications, tickets, names,
  errors) is shown with control characters, escape sequences and bidi overrides as visible
  escapes, so it cannot rewrite a `[y/N]` prompt. The history CSV quotes every field and guards
  formulas, also after `;` and tab.
- **`az`**: started with an argv array, never through a shell; tenant values (also from presets)
  are validated; looked up once, only in absolute `PATH` folders, and only a file that root or you
  own and nobody else can change; output capped, and a timeout ends it with everything it started.
- **URLs and listings**: scopes are percent-encoded with an ASCII allowlist; listings longer than
  100 pages or 20,000 items, or that loop, are errors instead of being cut short.
- **Files**: private files are created 600 in a 700 folder and never opened through a symbolic
  link; presets, `tokens.json` and the history are locked while they are written.
- **App state** belongs to one account and tenant: reminders act only for the account that
  activated the roles and require an unlocked Mac; switching account or tenant closes open
  confirmations and forgets their targets.
- **Install Command Line Tool** follows existing links before replacing them, leaves other users'
  links alone, and links `/usr/local/bin` only to a tool that only root or you can change.
- **Builds and releases**: read-only tokens except for the publish job, actions pinned to commit
  SHAs and the Linux container to a digest, no persisted checkout credentials; only version tags
  on `main` are released; the Windows package must hold exactly the reviewed runtime DLLs; every
  download has a SHA-256 and a build provenance attestation. The app and CLI are ad-hoc signed,
  not notarized.

### Changed

- Compared with Pimento's first, unpublished builds: the app binary is
  `Pimento.app/Contents/MacOS/Pimento` and the CLI a separate `pimento` (also
  `Contents/Helpers/pimento`); **Activate** always sends for real (the dry-run switch became
  **Preview**); `--role` matches whole role names (`*` as wildcard).
- **Deprecated**: the first builds' flags `pimento --list`, `--dry-run` and `--tenants` still work
  in 0.1.x (also on the app binary, which hands them to the CLI as read-only modes), print a note,
  and will be removed in a later release: use `pimento list`, `pimento activate --dry-run` and
  `pimento tenants`.

[Unreleased]: https://github.com/Melvin2306/pimento/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Melvin2306/pimento/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Melvin2306/pimento/releases/tag/v0.1.0
