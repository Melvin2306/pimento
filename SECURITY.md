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
  readable by other users; the loopback listener accepting a redirect without the right `state`,
  listening beyond the loopback interface, or staying open after sign-in;
- any way to make a preview or `--dry-run`, or a read-only command (`list`, `status`, `tenants`,
  `scheduled`, `pending`, `wait`, `approvals`, `history import-azure`), send a write request;
- a write sent without the confirmation it should have: a CLI write without its `[y/N]` answer or
  `--yes`, or Owner roles activated without the Owner confirmation;
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
- `az` is started with an argv array, never through a shell; tenant values are validated.
- The only write requests are the `roleAssignmentScheduleRequests` `PUT`s (activate, deactivate,
  renew, extend), `POST …/cancel` and the approval `PATCH` (approve, deny), from the app after you
  confirm or tap a reminder action, and from the CLI after its `[y/N]` prompt or `--yes`. Previews
  and `--dry-run` go through a transport that refuses anything but `GET`.
