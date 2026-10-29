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
- **Read-only CLI** in the same binary for scripting: `--list`, `--dry-run`, `--tenants`.
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

There are no notarized builds yet. Build it yourself (takes about a minute):

```sh
git clone https://github.com/melvin2306/pimento.git
cd pimento
scripts/bundle.sh --install      # builds Pimento.app and moves it to ~/Applications
```

Tagged releases also carry an ad-hoc signed `Pimento-<version>.zip`. Because it is not notarized,
macOS will refuse to open it at first: right-click the app and choose **Open**, or run
`xattr -dr com.apple.quarantine Pimento.app`.

## Build and run

```sh
swift build                    # debug build
swift test                     # unit tests (synthetic fixtures; never touches Azure)
swift run pimento              # launch the app straight from the build

scripts/bundle.sh              # release build -> build/Pimento.app (ad-hoc signed)
scripts/bundle.sh --zip        # ...plus build/Pimento-<version>.zip
open build/Pimento.app
```

## Usage

### The app

1. Make sure `az` is signed in: `az login` (or `az login --tenant <tenant>`).
2. Open Pimento. It loads your eligible roles for the selected tenant.
3. Filter with the search field, check rows, or press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>A</kbd> to select every
   role that is not active yet (within the current filter). Active rows cannot be checked.
4. Enter a **justification** and a **duration** (1 to 24 hours, default 8; each role's PIM policy
   sets its own maximum).
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
| <kbd>⌘</kbd><kbd>↩</kbd> | Preview / activate |
| <kbd>⌘</kbd><kbd>F</kbd> | Filter |

### Choosing the tenant

Pimento talks to one Microsoft Entra tenant at a time. It uses the first of:

1. `--tenant <id-or-domain>` on the command line (also works for the app: `open -a Pimento --args --tenant contoso.onmicrosoft.com`)
2. the `PIMENTO_TENANT` environment variable
3. the tenant you picked in the app's toolbar (remembered), or the one set under
   **Settings › General › Open with**
4. the tenant of az's current account (`az account show`)

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
| General | tenant to open with (last used, az's current, or a specific one); load roles on launch; refresh automatically (off, 1, 5 or 15 minutes); theme (see below); show or hide the Type, Membership and Condition columns (also via right-click on a column header); unhide hidden tenants |
| Activation | default duration; parallel requests (1 to 16, default 8); confirm before activating Owner roles (on by default); remember recent justifications and offer them from the clock button next to the field; start with the last one filled in |
| Notifications | macOS permission state, with a shortcut to System Settings when it is off; send a test notification; notify when activations finish, or only when something fails; expiry reminders and how long before (5, 10, 15 or 30 minutes); sound |

### Themes

*Settings › General › Appearance* switches the look of the main window, its sheets, the tenant
picker and the Settings window. The change applies right away. Only the styling changes: every
control, shortcut and accessibility label works the same in each theme.

| Theme | Look |
| --- | --- |
| Native (default) | The standard macOS look. |
| Azure-style | Flat and blue: the title bar and toolbar form one near-black portal-style top bar, with a "My roles" page title below it, the table on a white card with light-blue checked rows, portal-style status badges, square blue buttons. Light and dark. Uses Segoe UI if the Mac has it, otherwise the system font. |
| Windows XP-style | Beige window under a glossy blue title bar (the toolbar itself), a white list box with blue checked rows, light rounded buttons and a green **Activate** button (orange with Owner roles). Light only. Uses Tahoma if the Mac has it (macOS ships it), otherwise the system font. |

**Mode** next to the theme picks *System* (default, follows macOS), *Light* or *Dark* for every
Pimento window at once. Windows XP-style is light-only: while it is selected the mode shows
*Light* and is disabled, and your choice applies again when you switch to another theme.

In the themed looks the window's title bar and toolbar are coloured as one bar, with white title,
icons and toolbar controls; the controls themselves (tenant, Refresh, Settings, Select All
Eligible, Clear, search) stay the standard macOS ones. System alerts such as the Owner
confirmation keep the macOS look. No fonts, logos, icons, wallpapers or sounds are bundled.

The Azure-style and Windows XP-style themes are inspired by those designs. Pimento is not
affiliated with or endorsed by Microsoft.

### The command line

The app binary doubles as a **read-only** CLI. It uses a transport that refuses every
non-`GET` request, so it cannot activate anything.

```sh
pimento --tenants                              # tenants your az login can reach
pimento --list                                 # eligible roles in az's current tenant
pimento --list --tenant contoso.onmicrosoft.com
PIMENTO_TENANT=00000000-0000-0000-0000-000000000000 pimento --list

# Print the requests the app would send for not-yet-active Owner roles on
# resources whose name contains "prod" or "staging":
pimento --dry-run -j "INC-1234 investigate latency" --hours 4 --role owner prod staging
```

Inside the bundle the binary is `Pimento.app/Contents/MacOS/pimento`. During development use
`swift run pimento --list` or `.build/debug/pimento --list`.

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
4. **Activate.** For each selected role:
   `PUT {scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{new-guid}`
   with `requestType: SelfActivate`, `principalId` = you (also for group-inherited roles),
   `linkedRoleEligibilityScheduleId`, the justification and
   `scheduleInfo.expiration = {type: AfterDuration, duration: PT<n>H}`. If the eligibility
   carries an ABAC `condition`, it is copied verbatim together with `conditionVersion`;
   without it, ARM rejects the request.
5. **Results.** `RoleAssignmentExists` becomes *Skipped (already active)*;
   `RoleAssignmentRequestPolicyValidationFailed` lists the failing rules; token errors point
   to `az login`.

## Security and privacy

- Pimento acts **as you**, with your own `az` session. It has no app registration, service
  principal, secret or elevated permission of its own, and can do nothing you could not do in the portal.
- The access token is fetched on demand, **kept in memory only**, and sent **only to
  `management.azure.com`**. It is never written to disk, logged or displayed.
- It keeps its settings in `UserDefaults`: the chosen tenant ID, the hidden tenant IDs, table
  columns, the options from the Settings window and, unless you turn it off, your last
  10 justifications (Settings › Activation clears them).
- The only write call is the activation `PUT`. It runs only in the app, after you press
  Activate (and confirm, for Owner roles), or use **Preview** to see the requests without sending them.
- No analytics, no update checks, no third-party dependencies.

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## Limitations

- **Azure resource roles only** (management groups, subscriptions, resource groups, resources).
  **Microsoft Entra roles** (Global Administrator, ...) and **PIM for Groups** are managed through
  Microsoft Graph and need Graph permissions such as `RoleManagement.ReadWrite.Directory` /
  `PrivilegedAccess.ReadWrite.AzureADGroup`, which the Azure CLI's first-party app cannot obtain.
- **Approval-required roles** are submitted; the row shows *Submitted (PendingApproval)* until
  an approver acts.
- **Roles that require MFA or an authentication context** at activation fail with `MfaRule` /
  `AuthenticationContextRule` unless your az token already carries the required claims (see FAQ).
- Durations are whole hours.
- Not notarized (yet), so Gatekeeper asks before the first launch of a downloaded build.

## FAQ and troubleshooting

**"Not signed in" / `AADSTS...` errors.** Your az session has no valid token for that tenant.
Run the command the app shows, usually `az login --tenant <tenant>`, then press Retry.

**I see no roles, or the wrong ones.** Check the tenant in the toolbar. Pimento shows the
eligibilities of one tenant at a time; `pimento --tenants` lists the ones az knows about.

**`ExpirationRule` failed.** The duration exceeds the role's maximum activation time. Pick a
shorter duration (8 hours is PIM's default maximum).

**`JustificationRule` / `TicketingRule` failed.** The role's policy requires a justification or
ticket information. Pimento always sends a justification; ticket fields are not supported yet.

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
                         error mapping, tenant resolution, CLI parsing. Fully unit-tested.
Sources/PimentoApp/      SwiftUI app and the read-only CLI mode
Tests/PimentoCoreTests/  Swift Testing tests with synthetic JSON fixtures
Assets/                  app icon (generated by scripts/make-icon.swift)
scripts/bundle.sh        builds, signs (ad hoc) and optionally zips Pimento.app
scripts/make-icon.swift  draws the icon with CoreGraphics and runs iconutil
```

The app builds with the Command Line Tools alone. That is why it avoids SwiftUI's `@State`
macro, whose compiler plugin ships only with full Xcode in the macOS 26 SDK.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Melvin Rinkleff

Pimento is an independent project. It is not affiliated with or endorsed by Microsoft.
Microsoft, Azure and Microsoft Entra are trademarks of the Microsoft group of companies.
