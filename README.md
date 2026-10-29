<p align="center">
  <img src="Assets/AppIcon.iconset/icon_256x256.png" width="128" height="128" alt="Pimento app icon: a white shield with an upward arrow inside a countdown ring">
</p>

<h1 align="center">Pimento</h1>

<p align="center">
  <strong>Bulk-activate your Azure PIM roles from a native Mac app.</strong><br>
  Every eligible role on one screen. Pick the ones you need, give one justification, activate them in parallel.
</p>

<p align="center">
  <a href="https://github.com/melvin2306/pimento/actions/workflows/ci.yml"><img src="https://github.com/melvin2306/pimento/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-orange" alt="Swift 6.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

---

If you work with [Privileged Identity Management](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure)
for **Azure resources**, you know the routine: open the portal, find each subscription or
resource group, click *Activate*, type the same justification again, wait, repeat. Pimento
does the whole list in one go, as you, using the Azure CLI session you already have.

## Features

- **All your eligibilities in one table**: role, resource, scope type, whether you hold it
  directly or through a group, ABAC conditions, and whether it is active right now (and until when).
- **Bulk activation**: check the rows you need (or *Select All Eligible*), enter one justification,
  pick a duration, press <kbd>⌘</kbd><kbd>↩</kbd>. Requests run in parallel (8 at a time by default).
- **Per-row results**: *Activated until 17:42*, *Skipped (already active)*, or the exact policy rule
  that failed (`ExpirationRule`, `JustificationRule`, `MfaRule`, ...). Hover for the full ARM message.
- **Presets**: save a set of roles as "On-call" or "Deploy staging", with an optional justification
  and duration, then select or activate it in one click (<kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>9</kbd>) or with
  `pimento activate --preset On-call`. Presets belong to a tenant; roles you are no longer eligible
  for are reported, the rest is activated.
- **Each role's policy maximum**: Pimento reads every role's PIM policy and never asks for more
  than it allows. Pick a duration or *Maximum allowed*; the Duration column shows what each role
  gets (*8 h (max 8 h)*, or a warning when it is capped).
- **End early or renew**: check active rows (or right-click one) and press *Deactivate* to end them
  now, or *Renew* to end and activate them again for a fresh duration. Expiry reminders offer
  **Renew** and **End Now** right in the notification. See [Ending and renewing](#ending-and-renewing-activations).
- **Schedule for later**: set *Start* to *Tomorrow 08:00*, *Next working day 08:00* or any time up to
  30 days ahead and press *Schedule*; PIM activates the roles then. The **Scheduled** view lists your
  pending activations straight from Azure (also ones made elsewhere) with *Cancel*, rows show a
  *Scheduled Fri 08:00* badge, and an optional notification says when they start.
  See [Scheduled activations and tickets](#scheduled-activations-and-tickets).
- **Ticket information**: when a role's policy requires a ticket, ticket number and system fields
  appear (the row says *needs ticket*); any activation can carry one. Recent tickets are offered
  like recent justifications.
- **Approvals**: a role whose policy requires approval shows *Awaiting approval*; Pimento follows
  the request and notifies you when it is approved (with the expiry), denied (with the approver's
  reason), or expires. As an approver, **Approvals (N)** in the toolbar lists requests waiting for
  you, to approve or deny in bulk with a justification. See [Approvals](#approvals).
- **History**: every request Pimento sends, from the app and the CLI, with its outcome, in a
  searchable **History** window (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>H</kbd>) and `pimento history`. Export it as CSV,
  import your past requests from Azure (portal activity too), and *Activate Again* from a row.
  See [History](#history).
- **Preview (dry run)**: shows the exact `PUT` URLs and JSON bodies without sending anything (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>↩</kbd>).
- **Notifications**: a macOS notification when a batch finishes, and a reminder before activated roles
  expire (10 minutes by default; adjustable in Settings).
- **Owner safety net**: when the selection contains *Owner* roles, Pimento lists them and asks before sending anything.
- **Group-inherited eligibilities** work, and **ABAC conditions** on an eligibility (for example
  one that limits which roles the holder may assign) are carried over automatically.
- **Any tenant**: a searchable tenant picker in the toolbar shows every tenant by name, or pass
  `--tenant` / `PIMENTO_TENANT`. Hide the tenants you never use.
- **Settings** (<kbd>⌘</kbd><kbd>,</kbd>) for notifications, activation defaults, refresh and table columns.
- **Themes**: Native, Azure-style or, for fun, Windows XP-style (see [Themes](#themes)).
- **A real command-line tool**, `pimento`: `list`, `activate` (also `--at` and `--ticket`), `deactivate`, `renew`,
  `scheduled`, `cancel`, `pending`, `wait`, `approvals`, `approve`, `deny`, `status`, `tenants`, `history`, with JSON
  output, exit codes and shell completions. Download it on its own, or get it with the app.
- **No credentials of its own, no dependencies, no telemetry.**

## Screenshots

<!-- Add screenshots of the main window, the dry-run sheet and the Owner confirmation here.
     Use a demo tenant or blur names: no real subscription names, IDs or user names. -->

_Coming soon._

## Requirements

- macOS 14 Sonoma or later
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-macos) (`brew install azure-cli`), signed in with `az login`
- To build: Swift 6.0 or later (Xcode 16+, or just the Command Line Tools: `xcode-select --install`)

## Install

Pick one download from the [releases page](https://github.com/melvin2306/pimento/releases):

| Download | Contains | Good for |
| --- | --- | --- |
| `Pimento-<version>.zip` | Pimento.app, **with** the `pimento` command-line tool inside | the Mac app; turn on the CLI from its menu |
| `pimento-cli-<version>-macos.tar.gz` | only the `pimento` command-line tool (universal: Apple silicon and Intel), shell completions, LICENSE | terminals, scripts, no app wanted |

Each release also has `SHA256SUMS.txt` (`shasum -a 256 -c SHA256SUMS.txt --ignore-missing`).
Neither download is notarized yet, so macOS asks before the first launch (see below).

### Option 1: the app, with the CLI

1. Unzip `Pimento-<version>.zip` and move **Pimento.app** to Applications. On first launch,
   right-click the app and choose **Open**, or run `xattr -dr com.apple.quarantine Pimento.app`.
2. For the CLI, choose **Pimento › Install Command Line Tool…**. It links
   `Pimento.app/Contents/Helpers/pimento` into
   - `/usr/local/bin` (on every PATH; asks for an administrator password), or
   - `~/.local/bin` (no password; that folder must be on your PATH),

   and tells you what it did. **Pimento › Uninstall Command Line Tool…** removes the link again
   (only links that point to a Pimento.app). The link points into the app: after moving the app,
   install again. By hand: `ln -s /Applications/Pimento.app/Contents/Helpers/pimento ~/.local/bin/pimento`.

### Option 2: only the CLI

```sh
tar -xzf pimento-cli-<version>-macos.tar.gz
cd pimento-cli-<version>-macos
xattr -d com.apple.quarantine pimento 2>/dev/null || true   # not notarized
mkdir -p ~/.local/bin && mv pimento ~/.local/bin/            # or: sudo mv pimento /usr/local/bin/
pimento version
```

The `completions/` folder has scripts for zsh, bash and fish (see [Shell completions](#shell-completions)).

### From source

```sh
git clone https://github.com/melvin2306/pimento.git
cd pimento
scripts/bundle.sh --install      # Pimento.app (CLI inside) in ~/Applications
scripts/package-cli.sh           # or only the CLI: build/pimento-cli-<version>-macos.tar.gz
```

Homebrew is not available yet. Templates for a formula (CLI) and a cask (app) are in
[`packaging/homebrew/`](packaging/homebrew/), for when the repository is public.

## Build and run

```sh
swift build                    # debug build of the app, the CLI and the core
swift test                     # unit tests (synthetic fixtures; never touches Azure)
swift run PimentoApp           # launch the app straight from the build
swift run pimento list         # run the CLI straight from the build

scripts/bundle.sh              # release build -> build/Pimento.app (ad-hoc signed, CLI inside)
scripts/bundle.sh --zip        # ...plus build/Pimento-<version>.zip
scripts/package-cli.sh         # universal CLI -> build/pimento-cli-<version>-macos.tar.gz
open build/Pimento.app
```

## Usage

### The app

1. Make sure `az` is signed in: `az login` (or `az login --tenant <tenant>`).
2. Open Pimento. It loads your eligible roles for the selected tenant.
3. Filter with the search field, check rows, or press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>A</kbd> to select every
   role that is not active yet (within the current filter). Checking an *active* row selects it
   for **Renew** / **Deactivate** instead (see below).
4. Enter a **justification** and a **duration**: 1 to 24 hours (default 8), or *Maximum allowed*.
   Each role is requested for at most its PIM policy's maximum; the **Duration** column shows the
   maximum of every role and, for checked rows, the duration it will get.
   **Start** is *Now*, or a later time: the button then reads **Schedule N roles** (see
   [Scheduled activations and tickets](#scheduled-activations-and-tickets)). When a checked role's
   policy requires a ticket, fill in the ticket number and system that appear under the justification.
5. Press **Activate** (<kbd>⌘</kbd><kbd>↩</kbd>) to send the requests; Owner roles ask for confirmation
   first (a setting, on by default). **Preview** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>↩</kbd>) shows the request bodies instead, with
   *Copy All*, and sends nothing. The list refreshes afterwards.

| Shortcut | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>R</kbd> | Refresh |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>A</kbd> | Select all eligible (within the filter) |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd> | Clear selection |
| <kbd>⌘</kbd><kbd>K</kbd> | Clear results |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> | Choose tenant |
| <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> | Select the roles of the first nine presets |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>S</kbd> | Save selection as preset |
| <kbd>⌘</kbd><kbd>↩</kbd> | Preview / activate |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd> | Renew the checked active roles |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd> | End the checked active roles now |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd> | Scheduled activations |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> | Approvals (requests you can approve or deny) |
| <kbd>⌘</kbd><kbd>F</kbd> | Filter |

### Ending and renewing activations

Check active rows and the bottom bar offers **Renew** and **Deactivate**; right-clicking a row
offers *End Now…* and *Renew…* for it (or for all checked active rows when it is one of them).
Both ask first. The same actions are in the menu bar (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd>).

| Action | What Pimento sends | What happens |
| --- | --- | --- |
| **Deactivate** (End Now) | `SelfDeactivate` | The activation ends; the row goes back to *Eligible*. PIM refuses this in the first **5 minutes** after an activation; Pimento then shows *Too soon* with the time from which it works, and sends nothing. |
| **Renew** | `SelfDeactivate`, then `SelfActivate` | A fresh activation for the chosen duration (capped at the policy maximum). **In between the role is not active**: PIM accepts the new activation only once it has removed the old one, which took about **3 minutes** in tests. Pimento keeps trying for 5 minutes and shows *Activating again (try n)…*. If that fails, the role stays off: activate it again. Roles whose policy requires approval are not renewed. The new activation carries the ticket the current one was requested with (or the one in the ticket fields / `--ticket`); a role whose policy requires a ticket is skipped when none is known. |
| `pimento extend` (CLI) | `SelfExtend` | For **admin-assigned, time-bound** assignments: a *request* that an administrator must approve (`PendingAdminDecision`). Nothing changes until then. |

**Why Renew and not Extend?** PIM has no self-service way to lengthen your own activation.
Sending `SelfExtend` for an activation is accepted, but only as a request for an administrator
(`PendingAdminDecision`), and PIM keeps the old end time in it. Pimento therefore renews
activations, and uses `SelfExtend` only for admin-assigned time-bound assignments (where it is
the documented way to ask for more time).

Rows you end or renew keep their new state while Azure catches up (a refresh follows right away
and again after 20 and 60 seconds), the result column says what happened, and the completion
notification sums it up. Reminders for ended roles are withdrawn; renewed roles get new ones.

**From the expiry reminder.** The reminder has two actions:

- **Renew** renews the roles in the reminder for the duration they were activated for, with
  the same justification when Pimento keeps recent justifications (Settings › Activation). If
  there is no justification, or the roles include Owner (with the Owner confirmation on), the app
  comes forward and asks.
- **End Now** ends them right away.

Both act in the tenant the reminder is for; if the app shows another tenant, it says so instead.

### Scheduled activations and tickets

**Scheduling.** The **Start** menu in the bottom bar offers *Now*, *In 1 hour*, *Tomorrow 08:00*,
*Next working day 08:00* (Monday to Friday) and *Pick Date and Time…* (your local time zone). With a
later start the button reads **Schedule N roles** and Pimento sends a normal `SelfActivate` whose
`scheduleInfo.startDateTime` is that time. What PIM does with it, as tested:

- It accepts the request with status `Granted` and activates the role at the start, for the
  chosen duration (capped at the policy maximum as usual). Roles that need approval wait for it.
- It accepts a start up to **a month** ahead; later ones fail with `ScheduleStartTimeTooFarAhead`.
  Pimento offers up to 30 days.
- It also accepts a schedule for a role that is **active now**, for a start after the current
  activation ends (the CLI schedules such roles; one still active at the start is skipped).

The result column says *Scheduled for Fri 08:00*, and the start goes back to *Now* once a batch
was scheduled. **Scheduled** in the toolbar (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd>) lists your activations that
have not started and requests waiting for approval, read from Azure
(`roleAssignmentScheduleRequests`, `$filter=asTarget()`), so it includes requests made in the
portal or with the CLI. **Cancel** sends `POST …/roleAssignmentScheduleRequests/{id}/cancel`; a
request that started or was decided meanwhile cannot be cancelled (`RequestCannotBeCancelled`):
end an active role with *Deactivate*. Eligible rows with a pending request show *Scheduled Fri 08:00*
or *Awaiting approval*; active ones a calendar icon.

With **Notify when a scheduled activation starts** (Settings › Notifications, on by default)
Pimento schedules a local notification for each start time. It is rebuilt whenever the list is
read, so a request cancelled anywhere loses its notification at the next refresh. It is
best-effort: macOS shows it at the start time without checking that PIM activated the role.

**Tickets.** When a role's PIM policy has *Require ticket information on activation*
(`Ticketing` in the end-user enablement rule), its row says **needs ticket** and, once it is checked,
**ticket number** and **ticket system** fields appear under the justification; the button stays
disabled until both are filled in. Any activation can carry a ticket: the ticket button next to
the justification shows the fields. Pimento sends `ticketInfo: {ticketNumber, ticketSystem}` with
every request of the batch, remembers the last ticket system, and offers recent tickets from the
clock button (with *Remember recent justifications and tickets*). A preset can store a default
ticket system. If PIM still answers with a `TicketingRule` failure, the result says
*a ticket is required: give a ticket number and ticket system*.

### Approvals

**When your role needs approval.** PIM answers the activation with `PendingApproval`: the row
says *Awaiting approval* (hourglass), the completion notification lists it apart, and no expiry
reminder is set. The request appears under **Scheduled** with when you asked and when it expires
(an approver has **24 hours**, then PIM lets it time out); *Cancel* withdraws it. While any request
waits, Pimento reads your requests every minute (`roleAssignmentScheduleRequests`, `asTarget()`;
not when auto-refresh is set to 1 minute, which reads them anyway; paused during an activation)
and stops once none is left. When one is decided you get a notification:

- **Approved**: *Approved and active: Contributor*, with the end of the activation; the row turns
  active and gets its expiry reminder.
- **Denied**: with the approver's justification and name, when Azure lets you read the approval
  (`roleAssignmentApprovals/{id}/stages`; if not, without them).
- **Expired** (`TimedOut`) or **cancelled**.

**When you are an approver.** **Approvals** in the toolbar (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>; it reads
*Approvals (2)* when two wait) lists the requests you may decide: requester, role, resource,
duration and start, justification, ticket, when it was asked and when it expires. Check one or more
(or *All*), enter a justification (required; the requester sees it) and press **Approve** or
**Deny**. Deny always asks first; Approve asks when Owner roles are among them (with *Confirm before
activating Owner roles* on). Each row shows *Sending…*, then *Approved* / *Denied*, or why not (for
example decided by another approver meanwhile). The first approver's decision counts, and you
cannot approve your own requests. Without approver permissions the sheet simply says *You have no
approvals to review*. The list is read whenever Pimento refreshes; with *New approval requests* on
(Settings › Notifications), new ones get a notification that opens the sheet. For timely
notifications, turn on auto-refresh (Settings › General).

### History

Pimento keeps a log of every request it sends, from the app and from the `pimento` CLI:
activate, schedule, cancel, deactivate, renew, extend, approve and deny. Each entry holds the time,
the tenant (ID and name when known), role, resource and scope, the outcome (*Succeeded*, *Pending*,
*Skipped*, *Failed*, with Azure's status or error code and a short message), the duration asked for
and the one requested after the policy cap, the start, the justification, the ticket, the request ID,
where it came from (app or CLI) and the Pimento version. Never tokens, and never request or response
bodies. A renewal is one entry however many attempts it took. Previews and dry runs are not recorded.

**History…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>H</kbd>, the toolbar or the View menu) shows it as a table, newest
first, sortable by any column. Search (role, resource, justification, ticket, request ID), pick a
period (last 24 hours to last year, all time, or a custom range of days) and filter by action,
outcome and tenant. **Export CSV…** saves the rows shown, as filtered and sorted. Right-click a row
for **Activate Again** (checks that role and fills in its justification, ticket and duration; you
still press Activate) or **Copy Request ID**.

**Import from Azure** reads your own past requests in the current tenant
(`roleAssignmentScheduleRequests`, `$filter=asTarget()`, read-only) and adds the ones the history
does not have yet, marked *Azure*: activity from the portal or other tools shows up too. Requests are
matched by request ID, so importing twice adds nothing. Only your self-service requests are taken
(activate, deactivate, extend, renew), not assignments an administrator made.

**Settings › History** turns recording on or off (on by default), sets how long entries are kept
(30, 90 or 365 days, or forever; 1 year by default), shows the file in Finder and clears it (asks
first). The CLI follows the same settings.

#### History file

`~/Library/Application Support/Pimento/history.jsonl`, shared by the app and the CLI
(`PIMENTO_HISTORY` points both elsewhere, for the CLI or an app started from a terminal). It is
[JSON Lines](https://jsonlines.org): one object per line, mode 600. Every write takes an exclusive
lock on the file and appends each line with a single `write` on an `O_APPEND` descriptor, so the
app and the CLI can write at the same time. Past 5 MB the file becomes `history.1.jsonl` (replacing
an older one) and a new one starts. Entries older than the retention are removed when Pimento
starts, when it first records something, and when the retention changes. The settings are in
`history-settings.json` next to it (`{"enabled": true, "retentionDays": 365}`, 0 = forever).
Readers ignore fields they do not know and skip lines they cannot read.

```json
{"action":"activate","at":"2026-10-29T08:00:03.120Z","durationMinutes":240,"end":"2026-10-29T12:00:02.000Z","id":"5b3e…","justification":"CHG-1001 release 2.4","requestId":"7a1b2c3d-0000-4000-8000-000000000002","requestedDuration":"PT8H","result":"succeeded","roleDefinitionId":"/subscriptions/…/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c","roleName":"Contributor","scope":"/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b","scopeName":"Contoso Staging","scopeType":"subscription","source":"app","start":"2026-10-29T08:00:02.000Z","status":"Provisioned","tenantId":"11111111-2222-4333-8444-555555555555","tenantLabel":"Contoso","ticketNumber":"CHG-1001","ticketSystem":"ServiceNow","v":1,"version":"0.1.0"}
```

The CSV export is [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180): UTF-8, a header row, CRLF line
ends, fields with a comma, quote or line break quoted. Columns: `timestamp_utc` (ISO 8601),
`local_time`, `action`, `result`, `status`, `message`, `tenant_id`, `tenant`, `role`, `resource`,
`scope`, `requested_duration`, `duration_minutes`, `start_utc`, `end_utc`, `justification`,
`ticket_number`, `ticket_system`, `request_id`, `requester` (approve/deny), `source`,
`pimento_version`. A field that starts with `=`, `+`, `-`, `@`, a tab or a carriage return gets a
leading `'`, so a spreadsheet does not run it as a formula. The file is written with mode 600.

### Presets

A preset is a named set of eligibilities, with an optional justification and duration. Use the
**Presets** button in the toolbar or the **Presets** menu:

- **Save Selection as Preset…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>S</kbd>) saves the checked roles, and
  optionally the justification and duration.
- Picking a preset (<kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>9</kbd>) checks exactly its roles and fills in its
  justification and duration. A banner says which of its roles are already active and which you are
  no longer eligible for. **Activate Preset** does the same and activates right away; Owner roles
  still ask first when that setting is on.
- **Manage Presets…** renames, edits and deletes presets (including a default ticket system): tick roles in the list of your current
  eligibilities (active ones too), remove roles that no longer exist, or replace the roles with
  the checked ones.

Presets are saved per tenant; the menu shows the presets of the tenant you are looking at.
A role is identified by its scope and role definition, so a preset keeps working after renames.
The app and the `pimento` CLI share one file (see [Preset file](#preset-file)).

### Choosing the tenant

Pimento talks to one Microsoft Entra tenant at a time. It uses the first of:

1. `--tenant <id-or-domain>` on the command line (also for the app: `open -a Pimento --args --tenant contoso.onmicrosoft.com`)
2. the `PIMENTO_TENANT` environment variable
3. the tenant you picked in the app's toolbar (remembered), or the one set under
   **Settings › General › Open with**
4. the tenant of az's current account (`az account show`)

The `pimento` CLI uses 1, 2 and 4: it is stateless and does not read the app's settings.

The tenant picker (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd>, or click the tenant in the toolbar) lists every
tenant your login can reach, sorted by name, with the domain and a short ID underneath. Type to
search; <kbd>↩</kbd> picks the first match. Hover over a tenant and click the eye to hide it from the
list (*Show hidden* brings it back). Names come from ARM's `GET /tenants`, filled in from
`az account list --all` and `az account tenant list`; a tenant none of them names shows as
*Unnamed tenant* with the start of its ID. *Enter ID or Domain…* takes any tenant ID or domain.
With `--tenant` or `PIMENTO_TENANT` the picker is locked and says why.

### Settings

<kbd>⌘</kbd><kbd>,</kbd> opens Settings. Changes apply immediately; *Reset All Settings to Defaults*
is under General.

| Tab | Options |
| --- | --- |
| General | tenant to open with (last used, az's current, or a specific one); load roles on launch; refresh automatically (off, 1, 5 or 15 minutes); theme (see below); show or hide the Type, Membership, Condition and Duration columns (also via right-click on a column header); unhide hidden tenants |
| Activation | default duration; parallel requests (1 to 16, default 8); confirm before activating Owner roles (on by default); remember recent justifications and tickets and offer them from the clock buttons next to the fields; start with the last justification filled in |
| History | keep a history (on by default); keep records for 30, 90 or 365 days or forever; the file, Show in Finder, Clear History |
| Notifications | macOS permission state, with a shortcut to System Settings when it is off; send a test notification; notify when activations finish, or only when something fails; expiry reminders and how long before (5, 10, 15 or 30 minutes); notify when a scheduled activation starts; approval decisions on your requests; new approval requests for you; sound |

### Themes

*Settings › General › Appearance* switches the look of the main window, its sheets, the tenant
picker and the Settings window. The change applies right away. Only the styling changes: every
control, shortcut and accessibility label works the same in each theme.

| Theme | Look |
| --- | --- |
| Native (default) | The standard macOS look. |
| Azure-style | Flat and blue: the title bar and toolbar form one near-black portal-style top bar, with a "My roles" page title below it, the table on a white card with light-blue checked rows, portal-style status badges, square blue buttons. Light and dark. Uses Segoe UI if the Mac has it, otherwise the system font. |
| Windows XP-style | Beige window under a glossy blue title bar (the toolbar itself), a white list box with blue checked rows, light rounded buttons and a green **Activate** button (orange with Owner roles). Light only. Uses Tahoma if the Mac has it (macOS ships it), otherwise the system font. |

**Mode** next to the theme applies to every Pimento window at once:

| Mode | What applies |
| --- | --- |
| System (default) | Light or dark, following macOS. |
| Light, Dark | Always that. |
| Ultra dark | Dark with pure black (`#000000`) window, page, table and Settings backgrounds, for OLED screens and dark rooms: near-black surfaces and bottom bar (`#0A0A0A`), thin `#1F1F1F` borders, a black title bar and toolbar, accent-coloured selection; text stays at WCAG AA contrast or better. Native and Azure-style. |
| By time of day | *Light from* (07:00), *Dark from* (19:00) and, if ticked, *Ultra dark from* (23:00, off by default). Switches live at those times, also after sleep or a clock or time-zone change. Settings shows what applies now, e.g. *Now: Dark until 23:00*. |

The time-of-day rules, in local time: light lasts from its time until dark starts, dark until light
starts, either way round midnight (light from 20:00 and dark from 06:00 works). Ultra dark is a
later stage of the dark period, from its time until light starts. An ultra dark time inside the
light period (say 18:00 with dark from 19:00, or equal to the light time) starts ultra dark
together with dark; one equal to the dark time replaces dark. Equal light and dark times mean dark
all day. Settings notes when one of these rules moves a time. Pimento uses no location, sunrise
or sunset.

Windows XP-style is light-only, also by time of day: while it is selected the mode shows *Light*
and is disabled, and your choice (ultra dark or the schedule included) applies again when you
switch to another theme.

In the themed looks the window's title bar and toolbar are coloured as one bar, with white title,
icons and toolbar controls; the controls themselves (tenant, Refresh, Settings, Select All
Eligible, Clear, search) stay the standard macOS ones. System alerts such as the Owner
confirmation keep the macOS look. No fonts, logos, icons, wallpapers or sounds are bundled.

The Azure-style and Windows XP-style themes are inspired by those designs. Pimento is not
affiliated with or endorsed by Microsoft.

### The command line

<!-- cli-readme:start -->
`pimento` lists and activates your PIM roles from a terminal or a script. It runs the same
code as the app, with your `az login` session: the token stays in memory and is only sent to
`management.azure.com`.

```sh
pimento list                                 # eligible roles in az's current tenant, and which are active
pimento list prod --role Owner               # resource name contains "prod", role is exactly Owner
pimento list --eligible --tenant contoso.onmicrosoft.com
pimento status                               # active roles, soonest-expiring first, with time left
pimento tenants                              # tenants your az login can reach

# Activate: shows the plan, highlights Owner roles, asks [y/N]
pimento activate prod staging --role Reader -j "INC-1234 look at logs" --hours 2
# Show the exact PUT requests, send nothing
pimento activate --all -j "on-call" --dry-run
# From a script: --yes is required when stdin is not a terminal
pimento activate contoso-dev --role Contributor -j "deploy" --yes --json | jq .summary
# The longest each role's PIM policy allows
pimento activate prod --role Owner -j "INC-1234" --hours max

# Schedule for later, list what is pending, cancel it
pimento activate contoso-dev --role Contributor -j "release" --at "tomorrow 08:00"
pimento scheduled
pimento cancel 5f0c1d2e
# A role whose policy requires a ticket
pimento activate prod --role Owner -j "change" --ticket CHG-1001 --ticket-system ServiceNow

# Roles that need approval: see what waits, wait for the decision (exit 0 approved, 1 denied, 4 timeout)
pimento pending
pimento wait --all --timeout 2h && ./deploy.sh
# As an approver: list, approve or deny (asks first; --dry-run sends nothing)
pimento approvals
pimento approve 5f0c1d2e -j "matches CHG-1001"
pimento deny 7a1b -j "use the staging subscription"

# End roles early, or renew them for a fresh duration (asks first)
pimento deactivate contoso-dev --role Contributor
pimento renew contoso-dev --role Contributor -j "INC-1234 still on it" --hours 2
# Ask an administrator to extend an admin-assigned, time-bound assignment
pimento extend fabrikam --role Reader -j "project runs until March" --days 90

# Presets (shared with the app)
pimento presets save On-call prod --role Owner -j "on-call" --hours max
pimento activate --preset On-call
pimento presets list

# History (shared with the app): what was sent and how it went
pimento history --since 7d
pimento history --action approve,deny --outcome failed --json
pimento history export ~/Desktop/pim-history.csv --since 2026-10-01
pimento history import-azure --since 30d     # add your requests from the portal (read-only)
```

| Command | What it does |
| --- | --- |
| `pimento list [FILTER…] [--role NAME] [--active \| --eligible]` | Table of your eligible roles, with status and expiry |
| `pimento activate (FILTER… \| --role NAME \| --all \| --preset NAME) -j TEXT [--hours N\|max] [--at WHEN] [--ticket NUMBER [--ticket-system NAME]] [--yes] [--dry-run] [--max-parallel N]` | Activates the matching roles that are not active yet, in parallel (8 at a time by default), or schedules them with `--at` |
| `pimento deactivate (FILTER… \| --role NAME \| --all \| --preset NAME) [-j TEXT] [--yes] [--dry-run]` | Ends the matching activations now (`SelfDeactivate`) |
| `pimento renew (FILTER… \| --role NAME \| --all \| --preset NAME) -j TEXT [--hours N\|max] [--ticket NUMBER [--ticket-system NAME]] [--yes] [--dry-run]` | Ends and activates the matching roles again, for a fresh duration (the role is off for a few minutes in between), with the original activation's ticket or `--ticket` |
| `pimento extend (FILTER… \| --role NAME \| --all) -j TEXT [--days N] [--yes] [--dry-run]` | Asks an administrator to extend admin-assigned, time-bound assignments (`SelfExtend`) |
| `pimento scheduled` | Your scheduled activations and requests awaiting approval, from Azure |
| `pimento cancel (REQUEST-ID… \| FILTER… \| --role NAME \| --all) [--yes] [--dry-run]` | Cancels them (`POST …/cancel`) |
| `pimento pending` | Your requests waiting for approval, with when you asked and when they expire |
| `pimento wait (REQUEST-ID… \| --all) [--timeout 30m]` | Waits until they are decided (read-only, every 30 s): exit 0 approved, 1 denied/expired/cancelled/not found, 4 timeout |
| `pimento approvals` | Requests you can approve or deny as a PIM approver |
| `pimento approve REQUEST-ID… -j TEXT [--yes] [--dry-run]`, `pimento deny …` | Decides them (`PATCH …/roleAssignmentApprovals/{id}/stages/{stage}`) |
| `pimento status` | Active roles with the time left, soonest-expiring first |
| `pimento tenants` | Tenants by ID, name and domain |
| `pimento presets [list] \| show NAME \| save NAME FILTER… [--role NAME] [--exact] [-j TEXT] [--hours N\|max] [--ticket-system NAME] [--force] \| delete NAME` | Saved presets (see below) |
| `pimento history [WORD…] [--since WHEN] [--until WHEN] [--action NAME…] [--outcome NAME…] [--tenant ID\|NAME] [--limit N] [--json \| --csv]` | The history, newest first (50 rows in the table unless `--limit`; all with `--json`/`--csv`) |
| `pimento history export FILE.csv [filters]`, `history import-azure [--since WHEN]`, `history clear [--yes]` | CSV to a file (`-` for stdout); add your past requests from Azure (read-only); delete it (asks, or `--yes`) |
| `pimento completions zsh\|bash\|fish` | Prints a shell completion script |
| `pimento version`, `pimento help [COMMAND]` | Version; help for a command (also `COMMAND --help`) |

`list`, `activate`, `deactivate`, `renew`, `extend`, `scheduled`, `cancel`, `pending`, `wait`, `approvals`, `approve`,
`deny`, `status` and `tenants` take `-t, --tenant ID` and `--json`. The tenant is
`--tenant`, else `$PIMENTO_TENANT`, else az's current tenant.

**Selecting roles.** A FILTER matches the resource name (case-insensitive substring); several
filters are OR-ed. A filter starting with `/` is an ARM scope and matches it and everything below
it. `--role` matches the whole role name, case-insensitively, with `*` as a wildcard:
`--role owner` is Owner only, `--role '*owner'` also matches Storage Blob Data Owner. Repeat
`--role` for several roles. `activate` needs at least one FILTER, `--role`, `--all` or `--preset`.

**Duration.** `--hours N` (1 to 24, default 8) or `--hours max`. Before activating, `pimento` reads
each role's PIM policy (`roleManagementPolicyAssignments`) and requests at most its maximum: the
plan has a DURATION column and a note when a role was capped. When a policy cannot be read, the
asked duration is used (8 hours for `max`). `pimento list` shows the maximum in a MAX column.

**Scheduling.** `--at WHEN` schedules the activations instead of starting them now (see
[Scheduled activations](#scheduled-activations-and-tickets) for what PIM does). WHEN is read in your
local time zone unless it carries one:

| WHEN | Meaning |
| --- | --- |
| `now` | right away (the default) |
| `+90m`, `+1h`, `+1h30m`, `+2d` | from now (units `d`, `h`, `m`/`min`) |
| `08:00`, `8:30`, `8` | the next time it is that time: today if still ahead, else tomorrow |
| `today 17:00`, `tomorrow 08:00` (also `tomorrow08:00`) | that day |
| `mon 08:00` … `sunday 9:15` | the next such weekday (today if the time is still ahead) |
| `workday 08:00` | the next working day (Monday to Friday) after today |
| `2026-11-02 08:00`, `2026-11-02T08:00` | a local date and time |
| `2026-11-02T08:00:00Z`, `…+01:00`, `…-0500` | ISO 8601 with a zone |

A time in the past, more than 30 days ahead, or unreadable stops with exit code 2 before anything
is sent. A role that is active now is scheduled when its activation ends by the start, and skipped
when it is still active then. `pimento scheduled` lists pending activations (ID is the start of the
request id); `pimento cancel` takes request ids (the first 4 or more characters), resource filters,
`--role` or `--all`, shows what it will cancel and asks, like `activate`.

**Tickets.** `--ticket NUMBER --ticket-system NAME` sends `ticketInfo` with every request; any role
accepts it. When a role's policy requires a ticket and the number or the system is missing,
`activate` names the roles and stops with exit code 2 (checked against the policies it reads, also
in a dry run). A preset's ticket system (`presets save --ticket-system`) completes `--ticket`.

**Approvals.** A role whose policy requires approval is submitted: `activate` prints
`awaiting approval  Contributor · Contoso Staging (request 7a1b2c3d)`, a note that nothing is active
until an approver decides, and exits 0. `pimento pending` lists such requests (ASKED, EXPIRES:
approvers have 24 hours). `pimento wait ID…` (ids or their first 4+ characters, also already decided
ones) or `--all` reads your requests every 30 seconds until each is decided, printing *approved* with
the end of the activation, *denied* with the approver's justification when Azure shows it,
*expired* or *cancelled*. `--timeout` takes `30m` (default), `2h`, `1h30m`, `90s` or minutes, up to 24h.
Exit codes: 0 all approved, 1 any denied, expired, cancelled, failed or not found, 4 timed out.

`pimento approvals` lists the requests you can decide (an empty list, exit 0, when you have none or
no approver permissions). `pimento approve ID… -j TEXT` and `pimento deny ID… -j TEXT` follow the
safety rules below: the requests first (Owner roles highlighted for approve), a `[y/N]` prompt on a
terminal, `--yes` otherwise, `--dry-run` prints the `PATCH` and its body and sends nothing. A
request decided by someone else meanwhile is reported as not pending (exit 1).

**Ending and renewing.** `deactivate`, `renew` and `extend` follow the same safety rules as
`activate`: an explicit selection, the plan first, a `[y/N]` prompt on a terminal, `--yes` required
otherwise, and `--dry-run` sends nothing. `deactivate` and `renew` only consider active roles;
a role activated less than 5 minutes ago is reported as *too soon* with the time from which it
can be ended (exit code 1). `renew` warns that the role is off between the two requests, retries
the activation for up to 5 minutes while PIM removes the old one, and skips roles whose policy
requires approval. It sends the ticket the current activation was requested with, or `--ticket`
(with `--ticket-system`, or the preset's); a role whose policy requires a ticket is skipped when
neither is known. `extend` leaves PIM activations out (use `renew`) and asks for the end of each
matching admin-assigned assignment to move `--days` later (default 30); an administrator decides.
See [Ending and renewing](#ending-and-renewing-activations).

**Presets.** `pimento activate --preset NAME` activates the roles of a preset saved in the app or
with `pimento presets save`. The preset's justification and duration apply unless you pass `-j` or
`--hours`. Roles you are no longer eligible for are listed as *missing* and left out; the rest is
activated (exit code 1 only when none is left). A preset belongs to a tenant: without `--tenant`,
a preset name that exists in one tenant only uses that tenant.

`pimento presets save NAME FILTER… [--role NAME]` stores the filters as a *rule*, resolved each
time you activate, so new eligibilities that match are included; with `--exact` it stores the roles
that match now. It reads your roles (read-only) to find the tenant and shows what matches.
`--force` replaces a preset of the same name. `presets list`, `show` and `delete` work offline.

##### Preset file

The app and the CLI share `~/Library/Application Support/Pimento/presets.json`. Set
`PIMENTO_PRESETS` to use another file (for the CLI, or the app started from a terminal). It is
written atomically, readable only by you, and contains no secrets:

```json
{
  "version": 1,
  "presets": [
    {
      "id": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
      "name": "On-call",
      "tenantId": "11111111-2222-4333-8444-555555555555",
      "roles": [
        {
          "scope": "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a",
          "roleDefinitionId": "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
          "roleName": "Owner",
          "scopeName": "Contoso Production"
        }
      ],
      "match": [{ "filters": ["prod"], "roles": ["Owner"] }],
      "justification": "on-call",
      "duration": "max",
      "createdAt": "2026-10-29T12:00:00Z",
      "updatedAt": "2026-10-29T12:00:00Z"
    }
  ]
}
```

`roles` are matched by scope and role definition GUID, case-insensitively; the names are only for
display. `match` holds rules (`filters` and `roles` as on the command line). `duration` is `max` or
whole hours (`PT4H`); an optional `ticketSystem` completes `activate --ticket`; `tenantId` may be left out for a preset that applies to every tenant. Unknown
keys are ignored. A file with a higher `version` is refused rather than overwritten.

**Safety.** `activate` lists what it will send, marks Owner roles, and asks for confirmation on a
terminal. When stdin is not a terminal it refuses unless you pass `--yes`. Roles that are already
active are skipped, not sent again. `--dry-run` uses a transport that refuses anything but `GET`.

**Output.** Tables have aligned columns. On a terminal they are fitted to the window and coloured
(unless `NO_COLOR` is set) and show who you are signed in as and a total; piped, they are plain
columns for `grep` and `awk`. Prompts, notes and errors go to stderr. With `--json`, stdout gets
exactly one JSON document (the plan and progress of `activate` go to stderr):

| Command | JSON |
| --- | --- |
| `list`, `status` | `{tenantId, user: {objectId, name, upn}, roles: [{id, roleName, roleDefinitionId, scope, scopeName, scopeType, membership, group, isOwner, hasCondition, isActive, activeUntil, eligibilityScheduleId, secondsLeft, maxDuration, policy}]}` (`membership` is `direct` or `group`; `secondsLeft` only in `status`; `maxDuration` (ISO 8601, e.g. `PT8H`) and `policy: {status, maxDuration, requiresJustification, requiresTicket, requiresMfa, requiresApproval, authenticationContext, error}` only in `list`) |
| `tenants` | `{tenants: [{id, displayName, defaultDomain, category}]}` |
| `activate` | `{dryRun, tenantId, user, hours, duration, preset, justification, start, ticket: {ticketNumber, ticketSystem}, results: [{outcome, role, status, start, until, code, message, rules, request, duration, maxDuration, capped}], missing: [{scope, roleDefinitionId, roleName, scopeName}], summary: {activated, submitted, scheduled, skipped, failed, planned}}` (`outcome` is `activated`, `submitted` (pending approval), `scheduled` (`--at`), `skipped`, `failed` or `planned`; `start` and `summary.scheduled` only with `--at`; `request` only in a dry run; `duration` at the top is `max` or the asked ISO duration, `hours` only for a number; per result, `duration` is what was requested for that role) |
| `scheduled` | `{tenantId, user, requests: [{id, name, kind, status, start, end, duration, roleName, roleDefinitionId, scope, scopeName, scopeType, justification, ticketNumber, ticketSystem, createdOn}]}` (`kind` is `scheduled` or `awaitingApproval`; `name` is the request id) |
| `cancel` | `{dryRun, tenantId, user, results: [{outcome, request, code, message, url}], notFound, summary: {cancelled, failed, planned}}` (`outcome` is `cancelled`, `failed` or `planned`; `url` only in a dry run) |
| `pending` | as `scheduled`, only requests waiting for approval; each has `expiresAt` (also in `scheduled`) |
| `wait` | `{tenantId, user, timeout, results: [{target, outcome, status, request, until, reviewer, reviewJustification}], summary: {approved, rejected, timedOut, notFound}}` (`outcome` is `approved`, `denied`, `expired`, `canceled`, `failed`, `timeout` or `notFound`) |
| `approvals` | `{tenantId, user, available, note, requests: [{id, name, approvalId, stageId, requester: {objectId, name, email}, roleName, roleDefinitionId, scope, scopeName, scopeType, isOwner, status, start, end, duration, justification, ticketNumber, ticketSystem, createdOn, expiresAt}]}` (`available: false` with a `note` when Azure refused the listing) |
| `approve`, `deny` | `{decision, dryRun, tenantId, user, justification, results: [{outcome, request, code, message, url, body}], notFound, summary: {decided, skipped, failed, planned}}` (`outcome` is `approved`, `denied`, `planned`, `skipped` or `failed`; `url` and `body` only in a dry run) |
| `presets list`, `presets show` | `{file, presets: [{id, name, tenantId, roles, match, justification, duration, ticketSystem, createdAt, updatedAt}]}`; `show` prints one preset |

Times are ISO 8601 in UTC. Keys without a value are left out.

**Exit codes.**

| Code | Meaning |
| --- | --- |
| 0 | Success, including "nothing to do" (everything already active) |
| 1 | An activation or request failed, no role matched (or none of a preset's roles is eligible), or you answered no |
| 2 | Usage error: unknown option, no justification or selection, invalid tenant or `--at` time, a required ticket missing, or a command that changes roles without `--yes` when stdin is not a terminal |
| 3 | az is missing or not signed in, or ARM rejected the token (run the `az login` command it prints) |
| 4 | `pimento wait`: still no decision when `--timeout` ran out |

#### Shell completions

```sh
# zsh: any folder on $fpath, then restart the shell
pimento completions zsh > "${fpath[1]}/_pimento"
# bash (with bash-completion)
pimento completions bash > ~/.local/share/bash-completion/completions/pimento
# fish
pimento completions fish > ~/.config/fish/completions/pimento.fish
```

**Deprecated flags.** 0.1.0's `pimento --list`, `--dry-run` and `--tenants` still work in this
release (also on the app binary, which hands them to the bundled CLI). They print a note and go
away in the next release. `--dry-run` keeps its old meaning: `--role` matches a substring, and
without filters it plans every eligible role.
<!-- cli-readme:end -->

## How it works

Pimento calls [Azure Resource Manager](https://learn.microsoft.com/rest/api/authorization/privileged-role-assignment-rest-sample)
directly with the PIM APIs (`api-version=2020-10-01`):

1. **Token.** It runs `az account get-access-token --resource https://management.azure.com/`
   (plus `--tenant` when one is selected). The same token lists your tenants
   (`GET /tenants?api-version=2022-12-01`) for the tenant picker. `az` is looked up at `/opt/homebrew/bin/az`,
   `/usr/local/bin/az`, then `$PATH`. Your object ID comes from the token's `oid` claim.
2. **List eligible.**
   `GET /providers/Microsoft.Authorization/roleEligibilityScheduleInstances?$filter=asTarget()`
   at tenant level. `asTarget()` returns everything you are eligible for, **including
   eligibilities inherited through group membership**. `nextLink` pages are followed (only
   when they point back to `management.azure.com`).
3. **List active.** The same call for `roleAssignmentScheduleInstances`. An eligibility counts as
   active when an `Activated`, not-yet-expired instance exists for the same scope and role
   definition.
4. **Policy.** For each role, `GET {scope}/providers/Microsoft.Authorization/roleManagementPolicyAssignments?$filter=roleDefinitionId eq '…'`
   (a few at a time, cached for the session). Of its `effectiveRules`, Pimento reads the end-user
   activation rules: `Expiration_EndUser_Assignment.maximumDuration` (the longest activation),
   which of justification, ticket and MFA `Enablement_EndUser_Assignment` requires, whether
   `Approval_EndUser_Assignment` needs approval, and the authentication context.
5. **Activate.** For each selected role:
   `PUT {scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{new-guid}`
   with `requestType: SelfActivate`, `principalId` = you (also for group-inherited roles),
   `linkedRoleEligibilityScheduleId`, the justification and
   `scheduleInfo.expiration = {type: AfterDuration, duration: PT<n>H}` (at most the role's
   maximum, so it can also be `PT1H30M`). If the eligibility
   carries an ABAC `condition`, it is copied verbatim together with `conditionVersion`;
   without it, ARM rejects the request.
6. **Results.** `RoleAssignmentExists` becomes *Skipped (already active)*;
   `RoleAssignmentRequestPolicyValidationFailed` lists the failing rules; token errors point
   to `az login`.
7. **Deactivate.** The same `PUT` with `requestType: SelfDeactivate`, `principalId`, the role
   definition, `linkedRoleEligibilityScheduleId` and the eligibility's `condition` (if any), and no
   `scheduleInfo`. In an activation's first 5 minutes PIM answers `RoleAssignmentDoesNotExist`
   (Microsoft's docs also name `ActiveDurationTooShort`); both become *Too soon*.
   `RoleAssignmentDoesNotExist` later on means the activation had already ended.
8. **Renew** = 7, then 5 with a new request id and start time. Until PIM has removed the old
   assignment it answers `RoleAssignmentExists`; Pimento retries for about 5 minutes.
9. **Extend** (`pimento extend`): `requestType: SelfExtend` with `targetRoleAssignmentScheduleId`
   and `scheduleInfo.expiration = {type: AfterDateTime, endDateTime: <end + days>}`. PIM answers
   `201` with status `PendingAdminDecision`.
10. **Your requests** (Scheduled, `pending`, `wait`, Renew's ticket):
   `GET /providers/Microsoft.Authorization/roleAssignmentScheduleRequests?$filter=asTarget()` lists
   pending and past requests. A request waiting for approval has status `PendingApproval` and an
   `approvalId`; once decided it becomes `Provisioned`/`Granted`, `Denied`, `TimedOut` (after 24
   hours) or `Canceled`. A request's name is the last segment of the `targetRoleAssignmentScheduleId`
   it creates, which is how Renew finds the ticket an active role was requested with.
11. **History import**: the same `asTarget()` listing as 10, mapped to history entries (your
   `SelfActivate`, `SelfDeactivate`, `SelfExtend` and `SelfRenew` requests; a `SelfActivate`
   starting more than two minutes after it was made counts as scheduled) and merged by request name.
12. **Approvals** (approver side; the `roleAssignmentApprovals` API is a **preview**,
   `api-version=2021-01-01-preview`): `GET …/roleAssignmentScheduleRequests?$filter=asApprover()`
   (2020-10-01) lists the requests you may decide, with requester, role, schedule, justification and
   ticket; `GET /providers/Microsoft.Authorization/roleAssignmentApprovals?$filter=asApprover()`
   their stages (`asApprover()` is the only filter it accepts at the tenant root; anything else is a
   400). A decision is
   `PATCH /providers/Microsoft.Authorization/roleAssignmentApprovals/{approvalId}/stages/{stageId}`
   with `{"reviewResult": "Approve" | "Deny", "justification": "…"}` on the stage that is
   `InProgress` and `assignedToMe` (read from `…/stages` when the listing does not name it). A 400,
   403 or 404 listing means no approvals to show. Microsoft documents that ARM cannot approve
   extend and renew requests.

## Security and privacy

- Pimento acts **as you**, with your own `az` session. It has no app registration, service
  principal, secret or elevated permission of its own, and can do nothing you could not do in the portal.
- The access token is fetched on demand, **kept in memory only**, and sent **only to
  `management.azure.com`**. It is never written to disk, logged or displayed.
- It keeps its settings in `UserDefaults`: the chosen tenant ID, the hidden tenant IDs, table
  columns, the options from the Settings window and, unless you turn it off, your last
  10 justifications (Settings › Activation clears them).
- The only write calls are the `roleAssignmentScheduleRequests` `PUT`s (activate, deactivate,
  renew, extend), `POST …/cancel`, and the approval `PATCH` (approve, deny). They run after you
  confirm in the app (Activate and Approve ask for Owner roles; Deactivate, Renew, Cancel All and
  Deny always ask), after a tap on *Renew* / *End Now* in a reminder, or when the CLI command has
  your confirmation (or `--yes`). Following your requests for a decision is read-only (`GET`).
  **Preview** in the app and `pimento activate --dry-run` show the requests without sending them.
- Presets are kept in `~/Library/Application Support/Pimento/presets.json` (mode 600): names,
  ARM scopes and role definition IDs, and the justification and duration you chose to save.
- The **history** (`~/Library/Application Support/Pimento/history.jsonl`, mode 600) records what the
  app and the CLI sent: time, tenant, role, resource, outcome, duration, justification, ticket and
  request ID. No tokens, no request or response bodies; error messages are cut to one short line,
  and one that looks like a raw body is not kept. Turn it off or shorten the retention under
  Settings › History; *Clear History…* or `pimento history clear` deletes it. The CSV export is
  written with mode 600 too.
- The `pimento` CLI keeps no other state: no settings of its own, no token cache. It writes the
  presets file (`pimento presets save` and `delete`) and the history.
- No analytics, no update checks, no third-party dependencies (the CLI's argument parser is
  hand-written, so the build needs no package downloads).

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## Limitations

- **Azure resource roles only** (management groups, subscriptions, resource groups, resources).
  **Microsoft Entra roles** (Global Administrator, ...) and **PIM for Groups** are managed through
  Microsoft Graph and need Graph permissions such as `RoleManagement.ReadWrite.Directory` /
  `PrivilegedAccess.ReadWrite.AzureADGroup`, which the Azure CLI's first-party app cannot obtain.
- **Approval-required roles** are submitted and shown as *Awaiting approval* until an approver
  acts; they are not renewed (the role would be off until someone approves). Approving and denying
  uses ARM's **preview** approvals API; it was not exercised against a live approval while writing
  Pimento (see the changelog), and Microsoft documents that ARM cannot approve extend or renew requests.
- **The approver's reason** on a denied request is shown only when Azure lets the requester read the
  approval's stages.
- **New approval requests** are noticed when Pimento refreshes (and while your own requests wait);
  with auto-refresh off, that is at launch and on Refresh.
- **No self-service extension of an activation.** PIM does not offer one; *Renew* starts a new
  activation and leaves a gap of a few minutes. Extension requests for admin-assigned time-bound
  assignments are CLI-only (`pimento extend`), and the app does not list those assignments.
- **Reminder actions** need Pimento to be able to run: *End Now* works in the background, *Renew*
  brings the app forward. They act on the tenant the app is showing.
- **Roles that require MFA or an authentication context** at activation fail with `MfaRule` /
  `AuthenticationContextRule` unless your az token already carries the required claims (see FAQ).
- You choose whole hours (or *Maximum allowed*); a role whose policy allows less, such as 90
  minutes, is requested for exactly its maximum.
- **History** covers what Pimento sent from this Mac (and what *Import from Azure* reads). An
  approval request that is decided later keeps its *Pending* entry; importing does not update
  entries Pimento already has. Import reads one tenant at a time, only your own self-service
  requests, and only as far back as Azure lists them.
- Not notarized (yet), so Gatekeeper asks before the first launch of a downloaded build.
- The CLI is built and tested for macOS only. Its code avoids AppKit and imports
  `FoundationNetworking` where Linux needs it, but there is no Linux build in CI.

## FAQ and troubleshooting

**"Not signed in" / `AADSTS...` errors.** Your az session has no valid token for that tenant.
Run the command the app shows, usually `az login --tenant <tenant>`, then press Retry.

**I see no roles, or the wrong ones.** Check the tenant in the toolbar. Pimento shows the
eligibilities of one tenant at a time; `pimento tenants` lists the ones az knows about.

**`ExpirationRule` failed.** The duration exceeds the role's maximum activation time. Pimento
caps every request at the maximum it reads from the role's policy, so this only happens when the
policy could not be read (the Duration column shows *max ?*; hover for the reason). Pick a
shorter duration (8 hours is PIM's default maximum).

**`JustificationRule` / `TicketingRule` failed.** The role's policy requires a justification or
ticket information. Pimento always sends a justification; fill in the ticket fields (or pass
`--ticket NUMBER --ticket-system NAME`) for roles that need a ticket.

**`MfaRule` / `AuthenticationContextRule` failed, or a "claims challenge".** The role requires
MFA (or a Conditional Access authentication context) at activation. Sign in again so the token
carries the MFA claim, for example
`az logout && az login --tenant <tenant> --scope https://management.core.windows.net//.default`,
completing MFA in the browser. If the policy demands a specific authentication context, activate
those roles in the portal.

**`RoleAssignmentExists`.** The role was already active; Pimento reports it as skipped.

**`AuthorizationFailed` when listing.** Unusual, because the `asTarget()` listing needs no
permissions beyond being signed in. Check that the right tenant is selected and that your account
is a member (or guest) there.

**Azure CLI not found.** Install it with `brew install azure-cli`. Pimento looks in
`/opt/homebrew/bin`, `/usr/local/bin` and `$PATH`.

**Notifications don't show up.** *Settings › Notifications* shows what macOS allows. "Allowed,
but banners are off" means the banner style for Pimento is *None* (or alerts are turned off):
change it in System Settings › Notifications › Pimento. A Focus or Do Not Disturb mode also hides
banners; they still land in Notification Center. *Send Test Notification* reports whether macOS
accepted the test, or why not. If you built Pimento yourself, keep one copy: two
copies with the same bundle ID can confuse macOS. `scripts/bundle.sh --install` leaves only the one
in `~/Applications`.

**Does it work with sovereign clouds?** Not yet: the ARM endpoint is `management.azure.com`.

## Project layout

```
Sources/PimentoCore/     logic and ARM/az plumbing: models, matching, request bodies,
                         error mapping, tenant resolution. Fully unit-tested.
Sources/PimentoCore/CLI/ the CLI's commands: parser, selection, confirmation, exit codes,
                         tables, JSON, completions, install paths. Unit-tested.
Sources/pimento/         the `pimento` executable (Foundation only: terminal + network wiring)
Sources/PimentoApp/      SwiftUI app (product PimentoApp, Pimento.app/Contents/MacOS/Pimento)
Tests/PimentoCoreTests/  Swift Testing tests with synthetic JSON fixtures and a fake transport
Assets/                  app icon (generated by scripts/make-icon.swift)
scripts/bundle.sh        builds, signs (ad hoc) and optionally zips Pimento.app, CLI inside
scripts/package-cli.sh   builds the universal CLI and packs pimento-cli-<version>-macos.tar.gz
scripts/make-icon.swift  draws the icon with CoreGraphics and runs iconutil
packaging/homebrew/      unpublished Homebrew formula (CLI) and cask (app) templates
```

The app builds with the Command Line Tools alone. That is why it avoids SwiftUI's `@State`
macro, whose compiler plugin ships only with full Xcode in the macOS 26 SDK.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Melvin Rinkleff

Pimento is an independent project. It is not affiliated with or endorsed by Microsoft.
Microsoft, Azure and Microsoft Entra are trademarks of the Microsoft group of companies.
