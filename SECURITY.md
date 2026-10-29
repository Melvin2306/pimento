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
- any way to make the read-only CLI mode send a write request;
- activation requests sent while dry run is on, or Owner roles activated without confirmation;
- argument injection into the `az` process.

Out of scope: the security of Azure, Microsoft Entra ID or the Azure CLI themselves, and
anything that requires an attacker to already control your user account or `az` session.

## Design notes

- No credentials of its own: the token comes from `az account get-access-token`, is kept in
  memory only and is sent as a bearer token to `management.azure.com` only (pagination links to
  other hosts are not followed).
- `az` is started with an argv array, never through a shell; tenant values are validated.
- The only write request is the activation `PUT`, sent only from the app after explicit user action.
