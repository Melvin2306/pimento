# Pimento for Raycast

Activate and deactivate your Azure PIM roles and presets from Raycast. The extension is a thin
launcher for the [`pimento` command-line tool](../../README.md#the-command-line): it runs
`pimento … --json` and shows the result. It never talks to Azure and never sees a token; signing
in, the PIM policies, the confirmation rules and the history stay with the CLI.

| Command | What it does |
| --- | --- |
| **Search PIM Roles** | Your eligible roles (`pimento list`), active ones first with the time left. ↩ on an eligible role asks for a justification and a duration (and a ticket when its policy requires one), then activates exactly that role (`pimento activate --id …`). ↩ on an active role deactivates it after a confirmation. |
| **Activate PIM Preset** | Your presets (`pimento presets list`) with their roles. ↩ activates one after a confirmation, with its saved justification and duration; ⌘↩ (or ↩ when it has no justification) asks for a justification and duration first. |
| **Active PIM Roles** | The roles that are active now (`pimento status`), soonest-expiring first, with the time left (orange under an hour, red under 15 minutes). ↩ deactivates. |

Owner roles ask once more before they are activated. A role whose policy requires approval is
submitted and shows *Awaiting approval*: nothing is active until an approver decides.

## Requirements

- macOS with [Raycast](https://www.raycast.com) and Node.js 22 or later (only to install).
- The `pimento` CLI, signed in: `az login`, or `pimento login`
  (see [Install the command-line tool](../../README.md#install-the-command-line-tool)). The
  extension finds it in this order:
  1. the **pimento Path** preference, when set;
  2. `~/.local/bin/pimento` (where `scripts/install.sh` puts it);
  3. `PATH`, then `/opt/homebrew/bin` and `/usr/local/bin` (Raycast's own `PATH` is short);
  4. `/Applications/Pimento.app/Contents/Helpers/pimento`, the copy inside the app.

## Install

The extension is not in the Raycast Store. Install it from this folder:

```sh
cd integrations/raycast
npm ci
npm run dev        # imports the extension into Raycast; stop it with Ctrl-C, the extension stays
```

Then open Raycast and search for *Search PIM Roles*. To update, pull and run `npm run dev` again.

## Preferences

| Preference | Default | Meaning |
| --- | --- | --- |
| pimento Path | empty (look it up as above) | The `pimento` binary to run. `~` is expanded. |
| Tenant | empty | Passed as `--tenant` (GUID or domain). Empty: `$PIMENTO_TENANT`, then the signed-in tenant. A preset always uses its own tenant. |
| Demo Mode | off | Runs every command with `--demo`: a simulated Azure with synthetic data (Contoso), offline, without your files or tokens. Each command starts from the demo data, so an activation does not show up in the next list. Good for trying the extension and for screenshots. |

## Errors

Errors come from the CLI: the toast shows its message (the `error:` line on stderr) under a title
for its exit code. `pimento not found` means none of the paths above has it; set **pimento Path**.
*Not signed in* (exit code 3) means `az login` or `pimento login` in a terminal.

## How it runs the CLI

Every call is `execFile(pimento, [arguments])`: an argument list, no shell, so nothing in a
justification or a preset name is interpreted. Values are passed as `--option=value`, so text that
starts with `-` stays text. Commands that change roles pass `--yes`: the form or the confirmation
in Raycast is the confirmation the CLI would otherwise ask for on a terminal. A single role is
selected with `--id` (the `id` from `pimento list --json`), never with a name filter that could
also match its neighbours.

## Development

```sh
npm ci
npm run typecheck    # tsc --noEmit
npm run lint         # ray lint: manifest, icon, ESLint, Prettier
npm test             # src/lib/pimento.ts, including against `pimento --demo`
```

`npm test` runs the CLI from `$PIMENTO_BIN`, else the repository's debug build
(`swift build` at the top level); without either it skips the demo tests. The icon in `assets/` is
the app icon (`Assets/AppIcon.iconset/icon_512x512.png`).
