# Pimento for Alfred

An [Alfred](https://www.alfredapp.com) workflow (Alfred 5 with the Powerpack) for activating and
deactivating your Azure PIM roles and presets. It is a thin launcher for the
[`pimento` command-line tool](../../README.md#the-command-line): it runs `pimento … --json` and
shows the result. It never talks to Azure and never sees a token.

| Type | Does |
| --- | --- |
| `pim` | Your presets, your active roles with the time left, and your eligible roles |
| `pim WORDS` | Only those whose role, resource, type or group contains every word (`pim prod owner`) |
| ↩ on an eligible role | Fills in that role; type `>` and a justification, then ↩ activates it for the configured duration |
| ⌘↩ on it | The same, for the maximum its PIM policy allows |
| ↩ on a preset | Activates it with its saved justification and duration; `pim On-call > other reason` uses another justification |
| ⌥↩ on an active role | Deactivates it |

A role is picked by an `@` handle that ↩ fills in (`Contributor · Contoso Staging @924638b9 > `),
so the role you chose is the one activated (`pimento activate --id …`), never a neighbour with a
similar name. The result (activated until …, awaiting approval, or the CLI's error) comes as a
notification. Roles whose policy requires a ticket are shown but not activated from Alfred: use the
app or `pimento activate --ticket`.

The role list is cached for a minute while you type, and cleared by every action.

## Install

Requirements: macOS, Alfred 5 with the Powerpack, and the `pimento` CLI signed in (`az login` or
`pimento login`; see [Install the command-line tool](../../README.md#install-the-command-line-tool)).
The workflow uses only `/bin/sh` and JavaScript for Automation (`osascript`), both part of macOS.

```sh
integrations/alfred/build.sh     # writes build/Pimento.alfredworkflow
```

Open `build/Pimento.alfredworkflow` to import it into Alfred, then fill in its configuration:

| Setting | Default | Meaning |
| --- | --- | --- |
| pimento path | empty | The `pimento` binary. Empty: `~/.local/bin/pimento`, then `PATH`, `/opt/homebrew/bin` and `/usr/local/bin` (Alfred's `PATH` is short), then `/Applications/Pimento.app/Contents/Helpers/pimento`, skipping one that someone else could have placed or changed (the file or its folder not yours or root's, or writable by others or by a group other than wheel or admin). |
| Tenant | empty | Passed as `--tenant`. Empty: `$PIMENTO_TENANT`, then the signed-in tenant. A preset uses its own tenant. |
| Duration | 8 hours | The duration for ↩, capped at each role's maximum. |
| Demo mode | off | Runs everything with `--demo`: synthetic data (Contoso), offline, without your files or tokens. Each command starts from the demo data, so an activation does not show up in the next list. |

## Files

| File | Is |
| --- | --- |
| `info.plist` | The workflow: the `pim` Script Filter → Run Script → Post Notification, and its configuration |
| `scriptfilter.sh` | The Script Filter: runs `pimento list --json` and `presets list --json` (cached) |
| `action.sh` | The Run Script: `activate --id`, `activate --preset-id` or `deactivate --id`, with `--yes --json` |
| `lib.sh` | Shared: finding `pimento`, the cache, running it with an argument list |
| `alfred.js` | JXA: pimento's JSON → Alfred's JSON, and the notification text |
| `build.sh` | Packs the above with the app icon into `build/Pimento.alfredworkflow` |
| `test.sh` | Runs the scripts the way Alfred does against `pimento --demo` and checks their output |

Every value goes to `pimento` as its own argument (`--justification=TEXT`), never through a shell
string, so nothing you type is interpreted. ↩ is the confirmation the CLI would ask for on a
terminal, so the scripts pass `--yes`.

## Development

```sh
swift build                          # the CLI the tests run (.build/debug/pimento)
integrations/alfred/test.sh          # or: integrations/alfred/test.sh /path/to/pimento
shellcheck --shell=sh -x integrations/alfred/*.sh
```

`test.sh` needs `python3` to check the JSON; the workflow itself does not. The built
`.alfredworkflow` is not committed: build it from these files.
