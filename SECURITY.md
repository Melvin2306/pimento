# Security policy

Pimento activates privileged Azure role assignments with your own credentials, so security
reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub's
[private vulnerability reporting](https://github.com/Melvin2306/pimento/security/advisories/new)
(*Security* tab, *Report a vulnerability*). Only the maintainer sees the report. If that button
is ever missing, open an issue that asks for a private contact, without any details.

Include what you found, how to reproduce it, and the impact you see. You should get a first
answer within a week. Once a fix is released, the advisory is published with credit to you,
unless you prefer otherwise.

## Supported versions

| Version | Security fixes |
| --- | --- |
| 0.2.x (the latest release) | yes |
| 0.1.x, builds from before 0.1.0, and unreleased `main` | no |

Fixes ship as a new patch release of the latest version (0.2.x for now) and are listed under
*Security* in the [changelog](CHANGELOG.md). Please check that the problem still exists in the
[latest release](https://github.com/Melvin2306/pimento/releases/latest) before reporting.

## Scope

In scope, for example:

- the access token being written to disk, logged, displayed, or sent to any host other than
  `management.azure.com`;
- with Pimento sign-in: a refresh token, authorization code or PKCE verifier sent anywhere but
  `login.microsoftonline.com`, stored outside the Keychain (or the documented token file), or
  readable by other users (including the sign-in URL's `state`, `nonce` or PKCE challenge, for
  example through process arguments); the loopback listener accepting a redirect without the right
  `state`, listening beyond the loopback interface, leaving one of 127.0.0.1 and ::1 on its port
  to another program, or staying open after sign-in;
- any way to make a preview or `--dry-run`, or a read-only command (`list`, `status`, `tenants`,
  `scheduled`, `pending`, `wait`, `approvals`, `history import-azure`, and `mcp` without
  `--allow-activate`), send a write request;
- `pimento mcp` sending a write that the user was not asked to confirm through elicitation (when
  the client supports elicitation, whatever `--no-confirm` says), a write other than the plan the user
  confirmed, any write without `--allow-activate`, or an Owner, User Access Administrator or RBAC
  Administrator activation or renewal without `--allow-privileged` and its second confirmation;
  agent text (a justification, ticket or preset name) hiding characters from the confirmation;
  the server acting in another tenant than its `--tenant`, or its results carrying a token or a
  file path;
- keep alive renewing a role that can grant access (Owner, User Access Administrator, RBAC
  Administrator) that you did not confirm for it, renewing a role you paused or no longer keep
  alive, bringing back a role you ended (in Pimento or in the portal), renewing a role whose policy
  needs approval, or acting for another account or tenant than the one it was set up in;
- a write sent without the confirmation it should have: a CLI write without its `[y/N]` answer or
  `--yes`, a decision sent for another request than the one named, a cancel sent for another
  request than the one named, Owner roles activated without the Owner confirmation, a request for
  Owner, User Access Administrator or RBAC Administrator approved without its warning, or a
  reminder action run from a locked Mac;
- the app acting for another account or tenant than the one a confirmation, reminder or followed
  request belongs to (after switching accounts or tenants);
- text from Azure, Entra or other people (justifications, tickets, names, error messages) changing
  what the CLI shows on a terminal, or exported history turning into spreadsheet formulas;
- argument injection into the `az` process, or Pimento starting an `az` (or `xdg-open`, or, from
  the Raycast and Alfred launchers, a `pimento`) that someone else could have placed or changed,
  such as one in the current directory or a folder others can write;
- the command line tool link pointing somewhere other users can change, or Pimento replacing or
  removing another user's link;
- `scripts/install.sh` or `scripts/install.ps1` installing a file whose SHA-256 does not match the
  release's `SHA256SUMS.txt` (or whose attestation failed), or changing files outside the install
  folder, the shell completion folders and (on Windows) the user `Path`;
- the tenant logo fetch running while *Fetch tenant logos* is off, in demo mode or from the CLI,
  contacting a host other than `login.microsoftonline.com`, Microsoft's branding CDNs and the
  tenant's own verified domains (README › Security and privacy), sending a token, cookie, account
  or credential, or writing its cache outside its private folder;
- the update check sending more than its documented `GET` (any identifier, token or cookie), going
  to another host than `api.github.com`, running in demo mode or with `PIMENTO_NO_UPDATE_CHECK=1`,
  opening a link outside `https://github.com/Melvin2306/pimento/`, or downloading or installing
  anything; or a CLI command other than `pimento version --check` contacting GitHub.

Out of scope: the security of Azure, Microsoft Entra ID or the Azure CLI themselves, and
anything that requires an attacker to already control your user account or `az` session.

## Design notes

- The update check (README › Updates) is one `GET` of GitHub's latest release with only a
  `User-Agent: Pimento/<version>` header (besides fixed `Accept`, API-version and
  `Accept-Language` headers that are the same for everyone), through a guard that refuses any other URL or method and
  a private session (the logo fetch's) that keeps no cookies or credentials, refuses redirects and
  answers no authentication request but the server's certificate check. The answer is untrusted: the tag must parse as a strict
  semantic version, and the links opened are built from it, never copied from the answer.

- No secret of its own: by default the token comes from `az account get-access-token`; with
  Pimento sign-in, from the user's own public-client app registration (no client secret). Access
  tokens are kept in memory only and sent as bearer tokens to `management.azure.com` only
  (pagination links to other hosts are not followed).
- Pimento sign-in: authorization code with PKCE (S256), `state` and `nonce`, or the device code
  flow; a transport guard lets sign-in data reach only the HTTPS token and device-code endpoints of
  `login.microsoftonline.com`. Refresh tokens are kept in the login Keychain (this device only) or,
  without one, in a file (mode 600 on macOS and Linux; in the user profile on Windows); never logged
  or displayed.
- The CLI never puts the sign-in URL (`state`, `nonce`, PKCE challenge) in a process's arguments,
  which other local users can read on Linux: macOS opens it through LaunchServices; Linux gives
  `xdg-open` only the path of a private redirect page (mode 600 in a new 700 folder), removed when
  the sign-in is over. The CLI prints the URL to your terminal only when no browser could be
  opened, for opening it by hand.
- The sign-in redirect is `http://localhost:<random port>`. Pimento listens on both 127.0.0.1 and
  ::1 on that port, never on one side only (unless the system has no IPv6 loopback), so another
  local user's listener cannot receive the redirect. It serves up to 16 connections side by side,
  each with 5 seconds to send its request, so idle or slow local connections cannot hold back the
  browser's redirect. It takes the first request with the right `state` and closes. `http://127.0.0.1` would avoid the question of which address `localhost`
  resolves to, but Entra documents the ignored port only for `localhost` redirect URIs and accepts
  `http://127.0.0.1` only through a manifest edit, so Pimento keeps `localhost`.
- Every line the CLI writes to a terminal goes through one sanitiser: control characters, escape
  sequences other than its own colour codes, and bidi overrides in text from Azure, Entra or other
  people are shown as visible escapes, so a justification or a name cannot rewrite what a `[y/N]`
  prompt is about. JSON escapes them as `\uXXXX`.
- `az` is started with an argv array, never through a shell; tenant values (`--tenant`,
  `$PIMENTO_TENANT`, a preset's tenant) are validated. It is looked up once per process, only in
  absolute `PATH` folders (never the current directory), and only a file that root or you own and
  nobody else can change (nor its folder) is used; it runs with a `PATH` without relative entries,
  its output is capped, and cancelling ends it with everything it started. On Windows a batch file
  goes through `cmd.exe` only as an absolute path without special characters, with plain arguments.
- Pagination follows only `https://management.azure.com` links without credentials in them; a
  listing longer than 100 pages or 20,000 items, or one that links back to itself, is an error
  rather than a silently shortened list.
- The only write requests are the `roleAssignmentScheduleRequests` `PUT`s (activate, deactivate,
  renew, extend), `POST …/cancel` and the approval `PATCH` (approve, deny), from the app after you
  confirm or tap a reminder action (which macOS lets run only on an unlocked Mac; End Now on an
  Owner role asks in the app first), and from the CLI after its `[y/N]` prompt or `--yes`. Previews
  and `--dry-run`, the CLI's read-only commands and the app's reads go through a transport that
  refuses anything but `GET`. Renew leaves a role alone when its policy cannot be read.
- `pimento approve|deny --yes` decides only whole request ids, matched exactly: a requester cannot
  re-point a reviewed prefix to another request. Prefixes work on a terminal, where the prompt
  shows the whole id of the request it matched. `pimento cancel` treats a hex-only target as a
  request id that must match, never as a resource filter. Approving Owner, User Access
  Administrator or Role Based Access Control Administrator (roles that can grant access) warns and,
  in the app, asks; custom roles are not recognised, as Pimento reads no role definitions.
- App state belongs to one account and tenant: expiry reminders carry the object id of the account
  that activated the roles and act only for it (signing out removes them); switching account or
  tenant closes open confirmations and forgets their targets, followed approval requests and
  remembered tickets. Cancel asks first and sends only the requests it showed. Sign-in never
  falls back to another account when the chosen one is gone.
- Files: private files are created 600 in a 700 folder; lock, history and private files are never
  opened through a symbolic link; the history CSV quotes every field and guards formulas (`'`) at
  the start of a field and after each `;` or tab.
- Install Command Line Tool follows an existing link to the file it runs before calling it
  installed or replacing it, leaves other users' links alone, and links `/usr/local/bin/pimento`
  only to a tool that nobody but root or you can change. The app hands 0.1.0-style flags to the CLI
  only as its read-only modes.
- `pimento mcp` treats every tool argument as hostile. Without `--allow-activate` the write tools
  do not exist and every request goes through the GET-only transport. With it, each write is
  planned read-only, shown through MCP elicitation and planned again before sending; it is sent only
  if the new plan has the fingerprint the user confirmed (tool, tenant, account, roles, durations,
  justification, ticket). Stateless confirmations are single-use 256-bit handles bound to the tool
  and its exact arguments. Roles that can grant access also need `--allow-privileged` and a second
  box. String arguments are bounded in characters and Unicode scalars and refuse control, bidi,
  format and every default-ignorable character (an emoji's own presentation selector excepted),
  so the confirmation shows all of what is sent. `--tenant` limits every tool, `list_tenants` and
  the history included; results are filtered for tokens and file paths.
- Keep alive acts only for roles you marked (or a preset with *Keep alive*), with your own token
  and only through `SelfActivate` and the withdrawal of continuations it scheduled itself. Roles
  that can grant access need your confirmation once (or `--yes`); roles whose policy needs
  approval are never renewed; a role ended early (seen in the listing or your requests) is not
  brought back and its continuation is withdrawn; pausing withdraws continuations. Switching
  account or tenant starts it over, and a pass overtaken by that switch stops without touching the
  new state.
- Tenant logos (off by default; never in demo mode or the CLI) are fetched without a token, cookie
  or stored credential, over HTTPS to port 443 only, from Microsoft's sign-in endpoint and branding
  CDNs and, without a branding logo, the tenant's own verified domain (redirects only within it,
  3 at most), with size and image checks; the cache is keyed by tenant GUID and written private.
  Known gap: a guest tenant's administrator can point its domain at a loopback or internal
  address. TLS hostname checks stop any HTTP request there, leaving a blind TCP and TLS handshake
  to port 443 once per tenant every 7 days; URLSession offers no way to vet the address it connects
  to (a separate lookup first could be bypassed by DNS rebinding), so Pimento does not claim to
  refuse such addresses.
- Demo mode (`--demo`) refuses every network request, `az`, the sign-in listener and the browser
  openers for the whole process.
- Sign-out holds across processes: a refresh in another Pimento process replaces the stored refresh
  token only while it is the one it redeemed, and never re-creates a removed account.
- Builds: CI and releases run with read-only tokens (only the publish job can write the release),
  check out without keeping credentials, pin actions to commit SHAs and the Linux container to a
  digest. Only version tags on `main` are released, the Windows package holds exactly the reviewed
  runtime DLLs, and the Homebrew update checks each archive's attestation before using its sum.
  Release downloads carry GitHub build provenance attestations, and the install scripts check
  each download's SHA-256 (and, with a signed-in GitHub CLI, its attestation) before installing
  anything, without `sudo` or administrator rights. Known gaps: the Windows Swift
  toolchain is downloaded by its setup action at build time (pinned by version, not by checksum). The Mac app and CLI are
  ad-hoc signed and not notarized (no Developer ID): that is a known gap, outside this policy's
  fixes until a signing identity exists.
