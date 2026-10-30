# Security policy

Pimento activates privileged Azure role assignments with your own credentials, so security
reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub's
[private vulnerability reporting](https://github.com/melvin2306/pimento/security/advisories/new)
(*Security* tab, *Report a vulnerability*).

Include what you found, how to reproduce it, and the impact you see. You should get a first
answer within a week. Once a fix is released, the advisory is published with credit to you,
unless you prefer otherwise.

## Supported versions

Only the latest release receives security fixes.

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
  `scheduled`, `pending`, `wait`, `approvals`, `history import-azure`), send a write request;
- a write sent without the confirmation it should have: a CLI write without its `[y/N]` answer or
  `--yes`, a decision sent for another request than the one named, Owner roles activated without
  the Owner confirmation, or a reminder action run from a locked Mac;
- text from Azure, Entra or other people (justifications, tickets, names, error messages) changing
  what the CLI shows on a terminal, or exported history turning into spreadsheet formulas;
- argument injection into the `az` process.

Out of scope: the security of Azure, Microsoft Entra ID or the Azure CLI themselves, and
anything that requires an attacker to already control your user account or `az` session.

## Design notes

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
  the sign-in is over. The CLI also prints the URL to your terminal, for opening it by hand.
- The sign-in redirect is `http://localhost:<random port>`. Pimento listens on both 127.0.0.1 and
  ::1 on that port, never on one side only (unless the system has no IPv6 loopback), so another
  local user's listener cannot receive the redirect. It takes the first request with the right
  `state` and closes. `http://127.0.0.1` would avoid the question of which address `localhost`
  resolves to, but Entra documents the ignored port only for `localhost` redirect URIs and accepts
  `http://127.0.0.1` only through a manifest edit, so Pimento keeps `localhost`.
- Every line the CLI writes to a terminal goes through one sanitiser: control characters, escape
  sequences other than its own colour codes, and bidi overrides in text from Azure, Entra or other
  people are shown as visible escapes, so a justification or a name cannot rewrite what a `[y/N]`
  prompt is about. JSON escapes them as `\uXXXX`.
- `az` is started with an argv array, never through a shell; tenant values (`--tenant`,
  `$PIMENTO_TENANT`, a preset's tenant) are validated.
- The only write requests are the `roleAssignmentScheduleRequests` `PUT`s (activate, deactivate,
  renew, extend), `POST …/cancel` and the approval `PATCH` (approve, deny), from the app after you
  confirm or tap a reminder action (which macOS lets run only on an unlocked Mac; End Now on an
  Owner role asks in the app first), and from the CLI after its `[y/N]` prompt or `--yes`. Previews
  and `--dry-run`, the CLI's read-only commands and the app's reads go through a transport that
  refuses anything but `GET`. Renew leaves a role alone when its policy cannot be read.
- `pimento approve|deny --yes` decides only whole request ids, matched exactly: a requester cannot
  re-point a reviewed prefix to another request. Prefixes work on a terminal, where the prompt
  shows the whole id of the request it matched.
- Files: private files are created 600 in a 700 folder; lock, history and private files are never
  opened through a symbolic link; the history CSV quotes every field and guards formulas (`'`) at
  the start of a field and after each `;` or tab.
- Sign-out holds across processes: a refresh in another Pimento process replaces the stored refresh
  token only while it is the one it redeemed, and never re-creates a removed account.
- Builds: CI and releases run with read-only tokens (only the publish job can write the release),
  check out without keeping credentials, pin actions to commit SHAs and the Linux container to a
  digest. Release downloads carry GitHub build provenance attestations. The Mac app and CLI are
  ad-hoc signed and not notarized (no Developer ID): that is a known gap, outside this policy's
  fixes until a signing identity exists.
