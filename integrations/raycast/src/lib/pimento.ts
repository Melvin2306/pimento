// Runs the installed `pimento` CLI and reads its JSON. Nothing here talks to
// Azure or sees a token: the CLI does that. No Raycast imports, so the tests
// can load this file with plain Node.

import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

// MARK: - JSON shapes (README › The command line › Output)

export interface Policy {
  status?: string;
  maxDuration?: string;
  requiresJustification?: boolean;
  requiresTicket?: boolean;
  requiresMfa?: boolean;
  requiresApproval?: boolean;
  error?: string;
}

export interface Role {
  id: string;
  roleName: string;
  roleDefinitionId: string;
  scope: string;
  scopeName: string;
  scopeType: string;
  membership: "direct" | "group";
  group?: string;
  isOwner: boolean;
  hasCondition: boolean;
  isActive: boolean;
  activeUntil?: string;
  eligibilityScheduleId?: string;
  secondsLeft?: number;
  maxDuration?: string;
  policy?: Policy;
}

export interface User {
  objectId?: string;
  name?: string;
  upn?: string;
}

export interface RoleList {
  tenantId?: string;
  user?: User;
  roles: Role[];
}

export interface PresetRole {
  scope: string;
  roleDefinitionId: string;
  roleName?: string;
  scopeName?: string;
}

export interface PresetRule {
  filters?: string[];
  roles?: string[];
}

export interface Preset {
  id: string;
  name: string;
  tenantId?: string;
  roles?: PresetRole[];
  match?: PresetRule[];
  justification?: string;
  duration?: string;
  ticketSystem?: string;
}

export interface PresetList {
  file?: string;
  presets: Preset[];
}

export type Outcome =
  "activated" | "submitted" | "scheduled" | "skipped" | "failed" | "planned" | "deactivated" | string;

export interface Result {
  outcome: Outcome;
  role?: Role;
  status?: string;
  until?: string;
  code?: string;
  message?: string;
  requestId?: string;
  /** Deactivation too soon: when PIM allows it. */
  possibleAt?: string;
  capped?: boolean;
  duration?: string;
}

export interface Summary {
  activated?: number;
  submitted?: number;
  scheduled?: number;
  skipped?: number;
  failed?: number;
  planned?: number;
  deactivated?: number;
}

export interface ChangeResult {
  results: Result[];
  missing?: PresetRole[];
  summary: Summary;
}

// MARK: - Finding the binary

export const appHelperPath = "/Applications/Pimento.app/Contents/Helpers/pimento";

/** Directories Raycast's and Alfred's minimal PATH lacks, where Homebrew installs. */
const extraPathDirectories = ["/opt/homebrew/bin", "/usr/local/bin"];

export function expandHome(path: string, home = homedir()): string {
  if (path === "~") return home;
  if (path.startsWith("~/")) return join(home, path.slice(2));
  return path;
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * The `pimento` to run: the configured path when there is one (used as is,
 * even if missing, so the error names it); otherwise ~/.local/bin/pimento,
 * then PATH (plus the Homebrew folders), then the copy inside Pimento.app.
 */
export function candidatePaths(
  configured: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
): string[] {
  const own = configured?.trim();
  if (own) return [expandHome(own, home)];
  const dirs = (env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const d of extraPathDirectories) if (!dirs.includes(d)) dirs.push(d);
  return [join(home, ".local/bin/pimento"), ...dirs.map((d) => join(d, "pimento")), appHelperPath];
}

export function findPimento(
  configured: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
  exists: (path: string) => boolean = isExecutable,
): string | undefined {
  const own = configured?.trim();
  if (own) return expandHome(own);
  return candidatePaths(undefined, env).find(exists);
}

// MARK: - Running it

export interface Settings {
  /** Path from the preferences; empty: look it up. */
  pimentoPath?: string;
  demo?: boolean;
  tenant?: string;
}

export interface RunOutput {
  code: number;
  stdout: string;
  stderr: string;
}

/** What went wrong, for a toast: a short title and the CLI's own words. */
export class PimentoError extends Error {
  // Plain fields, not parameter properties: Node's type stripping (the tests) cannot run those.
  readonly title: string;
  readonly code: number | "ENOENT" | "TIMEOUT";
  readonly stderr: string;

  constructor(title: string, message: string, code: number | "ENOENT" | "TIMEOUT", stderr = "") {
    super(message);
    this.name = "PimentoError";
    this.title = title;
    this.code = code;
    this.stderr = stderr;
  }
}

/** The global options every call gets: `--demo`, `--tenant`. */
export function baseArgs(settings: Settings, opts: { tenant?: boolean } = {}): string[] {
  const args: string[] = [];
  if (settings.demo) args.push("--demo");
  const tenant = settings.tenant?.trim();
  if (tenant && opts.tenant !== false) args.push(`--tenant=${tenant}`);
  return args;
}

/** The last `error:` line of stderr, else its last line. */
export function errorMessage(stderr: string): string {
  const lines = stderr
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  const error = [...lines].reverse().find((l) => l.toLowerCase().startsWith("error:"));
  const line = error ?? lines[lines.length - 1] ?? "";
  return line.replace(/^error:\s*/i, "");
}

/** Exit code → title, as in `pimento help` (README › Exit codes). */
export function errorTitle(code: number): string {
  switch (code) {
    case 1:
      return "Pimento: it did not work";
    case 2:
      return "Pimento: not possible as asked";
    case 3:
      return "Pimento: not signed in";
    case 4:
      return "Pimento: timed out";
    default:
      return `Pimento failed (exit code ${code})`;
  }
}

export function failure(output: RunOutput): PimentoError {
  let message = errorMessage(output.stderr) || "No details on stderr.";
  if (output.code === 3 && !/az login|pimento login/.test(message)) {
    message += " Run `az login` or `pimento login` in a terminal.";
  }
  return new PimentoError(errorTitle(output.code), message, output.code, output.stderr);
}

export function run(binary: string | undefined, args: string[], opts: { timeoutMs?: number } = {}): Promise<RunOutput> {
  if (!binary) {
    return Promise.reject(
      new PimentoError(
        "pimento not found",
        `Looked in ~/.local/bin, PATH and ${appHelperPath}. Install the CLI or set its path in the extension's preferences.`,
        "ENOENT",
      ),
    );
  }
  return new Promise((resolve, reject) => {
    execFile(
      binary,
      args,
      {
        timeout: opts.timeoutMs ?? 120_000,
        maxBuffer: 32 * 1024 * 1024,
        env: { ...process.env, NO_COLOR: "1" },
        encoding: "utf8",
      },
      (error, stdout, stderr) => {
        if (!error) return resolve({ code: 0, stdout, stderr });
        const e = error as NodeJS.ErrnoException & {
          code?: number | string;
          killed?: boolean;
          signal?: string;
        };
        if (e.code === "ENOENT" || e.code === "EACCES") {
          return reject(
            new PimentoError(
              "pimento not found",
              `${binary} does not exist or cannot be run. Set the path in the extension's preferences.`,
              "ENOENT",
            ),
          );
        }
        if (e.killed || e.signal) {
          return reject(
            new PimentoError("Pimento timed out", `pimento ${args.join(" ")} did not finish.`, "TIMEOUT", stderr),
          );
        }
        if (typeof e.code === "number") return resolve({ code: e.code, stdout, stderr });
        reject(new PimentoError("Pimento failed", e.message, 1, stderr));
      },
    );
  });
}

/** Runs a read-only command and parses its JSON; a non-zero exit throws. */
export async function readJSON<T>(binary: string | undefined, args: string[]): Promise<T> {
  const output = await run(binary, args);
  if (output.code !== 0) throw failure(output);
  try {
    return JSON.parse(output.stdout) as T;
  } catch {
    throw new PimentoError(
      "Pimento: unexpected output",
      "Its JSON could not be read. Is this a current pimento?",
      1,
      output.stderr,
    );
  }
}

/**
 * Runs `activate` / `deactivate` with `--json`: exit 0 or 1 with a result
 * document is a result (some roles may have failed); anything else throws.
 */
export async function change(binary: string | undefined, args: string[]): Promise<ChangeResult> {
  const output = await run(binary, args);
  if (output.code === 0 || output.code === 1) {
    try {
      const parsed = JSON.parse(output.stdout) as ChangeResult;
      if (Array.isArray(parsed.results)) return parsed;
    } catch {
      // No result document: fall through to the error on stderr.
    }
  }
  throw failure(output);
}

// MARK: - Commands

export function listArgs(settings: Settings): string[] {
  return [...baseArgs(settings), "list", "--json"];
}

export function statusArgs(settings: Settings): string[] {
  return [...baseArgs(settings), "status", "--json"];
}

export function presetsArgs(settings: Settings): string[] {
  // Presets are per tenant; list all of them (the file is local, no sign-in).
  return [...baseArgs(settings, { tenant: false }), "presets", "list", "--json"];
}

export interface ActivateInput {
  justification: string;
  /** "1"…"24" or "max"; empty: the CLI's default (8 hours). */
  hours?: string;
  ticketNumber?: string;
  ticketSystem?: string;
}

/** Every value goes after `=`, so text that starts with "-" stays a value. */
function activationOptions(input: Partial<ActivateInput>): string[] {
  const args: string[] = [];
  const justification = input.justification?.trim();
  if (justification) args.push(`--justification=${justification}`);
  const hours = input.hours?.trim();
  if (hours) args.push(`--hours=${hours}`);
  const ticket = input.ticketNumber?.trim();
  if (ticket) {
    args.push(`--ticket=${ticket}`);
    const system = input.ticketSystem?.trim();
    if (system) args.push(`--ticket-system=${system}`);
  }
  return args;
}

export function activateRoleArgs(settings: Settings, role: Pick<Role, "id">, input: ActivateInput): string[] {
  return [...baseArgs(settings), "activate", `--id=${role.id}`, ...activationOptions(input), "--yes", "--json"];
}

export function activatePresetArgs(
  settings: Settings,
  preset: Pick<Preset, "name" | "tenantId">,
  input: Partial<ActivateInput> = {},
): string[] {
  // The preset's own tenant wins over the preference: that is where its roles are.
  const tenant = preset.tenantId ? [`--tenant=${preset.tenantId}`] : [];
  return [
    ...baseArgs(settings, { tenant: !preset.tenantId }),
    "activate",
    `--preset=${preset.name}`,
    ...tenant,
    ...activationOptions(input),
    "--yes",
    "--json",
  ];
}

export function deactivateArgs(settings: Settings, role: Pick<Role, "id">): string[] {
  return [...baseArgs(settings), "deactivate", `--id=${role.id}`, "--yes", "--json"];
}

// MARK: - Formatting

/** "PT8H" → "8 h", "PT1H30M" → "1 h 30 min", "max" → "maximum". */
export function formatDuration(iso: string | undefined): string | undefined {
  if (!iso) return undefined;
  if (iso.toLowerCase() === "max") return "maximum";
  const m = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$/i.exec(iso);
  if (!m) return iso;
  const hours = Number(m[1] ?? 0) * 24 + Number(m[2] ?? 0);
  const minutes = Number(m[3] ?? 0);
  if (hours && minutes) return `${hours} h ${minutes} min`;
  if (hours) return `${hours} h`;
  return `${minutes} min`;
}

/** Hours in an ISO duration, for the duration choices a role allows. */
export function durationHours(iso: string | undefined): number | undefined {
  const m = iso ? /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$/i.exec(iso) : null;
  if (!m) return undefined;
  return Number(m[1] ?? 0) * 24 + Number(m[2] ?? 0) + Number(m[3] ?? 0) / 60;
}

/** "2h 39m", "7m", "<1m", like `pimento status`. */
export function formatTimeLeft(until: string | undefined, now: Date = new Date()): string | undefined {
  if (!until) return undefined;
  const end = Date.parse(until);
  if (Number.isNaN(end)) return undefined;
  const seconds = Math.floor((end - now.getTime()) / 1000);
  if (seconds <= 0) return "ended";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 1) return "<1m";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}m`;
  return `${h}h ${String(m).padStart(2, "0")}m`;
}

export function secondsLeft(role: Pick<Role, "activeUntil">, now: Date = new Date()): number | undefined {
  if (!role.activeUntil) return undefined;
  const end = Date.parse(role.activeUntil);
  return Number.isNaN(end) ? undefined : Math.floor((end - now.getTime()) / 1000);
}

export function formatClock(iso: string | undefined): string | undefined {
  if (!iso) return undefined;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return undefined;
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

export function roleLabel(role: Pick<Role, "roleName" | "scopeName">): string {
  return `${role.roleName} · ${role.scopeName}`;
}

export function scopeTypeLabel(scopeType: string): string {
  switch (scopeType.toLowerCase()) {
    case "subscription":
      return "Subscription";
    case "resourcegroup":
      return "Resource group";
    case "managementgroup":
      return "Management group";
    case "":
    case "resource":
      return "Resource";
    default:
      return scopeType.charAt(0).toUpperCase() + scopeType.slice(1);
  }
}

export interface Toast {
  style: "success" | "failure";
  title: string;
  message?: string;
}

/** One toast for an `activate` / `deactivate` result. */
export function describe(result: ChangeResult): Toast {
  const s = result.summary ?? {};
  const failed = result.results.filter((r) => r.outcome === "failed");
  const one = result.results.length === 1 ? result.results[0] : undefined;
  const label = one?.role ? roleLabel(one.role) : undefined;
  const missing = result.missing?.length ?? 0;
  const parts: string[] = [];
  if (s.activated) parts.push(`${s.activated} activated`);
  if (s.deactivated) parts.push(`${s.deactivated} deactivated`);
  if (s.submitted) parts.push(`${s.submitted} awaiting approval`);
  if (s.scheduled) parts.push(`${s.scheduled} scheduled`);
  if (s.skipped) parts.push(`${s.skipped} already done`);
  if (s.failed) parts.push(`${s.failed} failed`);
  if (missing) parts.push(`${missing} no longer eligible`);

  if (failed.length > 0) {
    const f = failed[0];
    const from = formatClock(f.possibleAt);
    const why = [f.code, f.message].filter(Boolean).join(": ") + (from ? ` (possible from ${from})` : "");
    return {
      style: "failure",
      title: one ? `Failed: ${label}` : parts.join(", ") || "Failed",
      message: f.role ? `${roleLabel(f.role)}: ${why || f.outcome}` : why || undefined,
    };
  }
  if (one) {
    switch (one.outcome) {
      case "activated": {
        const until = formatClock(one.until);
        return { style: "success", title: `Activated ${label}`, message: until ? `Until ${until}` : undefined };
      }
      case "submitted":
        return {
          style: "success",
          title: `Awaiting approval: ${label}`,
          message: `Nothing is active until an approver decides${one.requestId ? ` (request ${one.requestId.slice(0, 8)})` : ""}.`,
        };
      case "deactivated":
        return { style: "success", title: `Deactivated ${label}` };
      case "skipped":
        return {
          style: "success",
          title: `Nothing to do: ${label}`,
          message: one.message ?? "Already active.",
        };
      default:
        break;
    }
  }
  if (parts.length === 0) return { style: "success", title: "Nothing to do" };
  return { style: "success", title: parts.join(", ") };
}
