// Tests for src/lib/pimento.ts: the pure helpers, and the whole round trip
// against `pimento --demo` (offline, synthetic data). Run with
// `npm test` (Node 22.18+ runs TypeScript directly). The demo tests use
// $PIMENTO_BIN, else the repository's debug build (`swift build`), and are
// skipped when neither exists.

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { describe as suite, test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  activatePresetArgs,
  activateRoleArgs,
  appHelperPath,
  baseArgs,
  candidatePaths,
  change,
  deactivateArgs,
  describe,
  durationHours,
  errorMessage,
  failure,
  findPimento,
  formatDuration,
  formatTimeLeft,
  listArgs,
  PimentoError,
  presetsArgs,
  readJSON,
  run,
  statusArgs,
  type ChangeResult,
  type PresetList,
  type Role,
  type RoleList,
} from "../src/lib/pimento.ts";

const here = dirname(fileURLToPath(import.meta.url));
const debugBuild = resolve(here, "../../../.build/debug/pimento");
const bin = process.env.PIMENTO_BIN ?? (existsSync(debugBuild) ? debugBuild : undefined);
const demo = { demo: true };

suite("finding pimento", () => {
  test("a configured path wins and ~ is expanded", () => {
    assert.equal(findPimento("~/bin/pimento", {}, () => false), join(process.env.HOME ?? "", "bin/pimento"));
    assert.deepEqual(candidatePaths(" /opt/pimento ", {}, "/home/a"), ["/opt/pimento"]);
  });

  test("default order: ~/.local/bin, PATH, Homebrew, the app", () => {
    const paths = candidatePaths("", { PATH: "/usr/bin:/opt/homebrew/bin" }, "/home/a");
    assert.deepEqual(paths, [
      "/home/a/.local/bin/pimento",
      "/usr/bin/pimento",
      "/opt/homebrew/bin/pimento",
      "/usr/local/bin/pimento",
      appHelperPath,
    ]);
    const found = findPimento(undefined, { PATH: "/usr/bin" }, (p) => p === "/usr/local/bin/pimento");
    assert.equal(found, "/usr/local/bin/pimento");
    assert.equal(
      findPimento(undefined, { PATH: "" }, () => false),
      undefined,
    );
  });

  test("relative PATH entries are never searched", () => {
    const paths = candidatePaths("", { PATH: ".:bin::/usr/bin" }, "/home/a");
    assert.deepEqual(paths, [
      "/home/a/.local/bin/pimento",
      "/usr/bin/pimento",
      "/opt/homebrew/bin/pimento",
      "/usr/local/bin/pimento",
      appHelperPath,
    ]);
  });
});

suite("arguments", () => {
  const role = { id: "/subscriptions/00000000-0000-0000-0000-000000000001/x/i1" };

  test("demo and tenant go first, values after =", () => {
    assert.deepEqual(baseArgs({ demo: true, tenant: " contoso.example " }), ["--demo", "--tenant=contoso.example"]);
    assert.deepEqual(listArgs({}), ["list", "--json"]);
    assert.deepEqual(statusArgs(demo), ["--demo", "status", "--json"]);
    // Presets are local and per tenant: no --tenant.
    assert.deepEqual(presetsArgs({ demo: true, tenant: "t" }), ["--demo", "presets", "list", "--json"]);
  });

  test("activate a role by id; a justification starting with - stays a value", () => {
    assert.deepEqual(activateRoleArgs(demo, role, { justification: " --all; rm -rf ~ ", hours: "max" }), [
      "--demo",
      "activate",
      `--id=${role.id}`,
      "--justification=--all; rm -rf ~",
      "--hours=max",
      "--yes",
      "--json",
    ]);
    assert.deepEqual(
      activateRoleArgs({}, role, { justification: "x", ticketNumber: "CHG-1", ticketSystem: "ServiceNow" }),
      ["activate", `--id=${role.id}`, "--justification=x", "--ticket=CHG-1", "--ticket-system=ServiceNow", "--yes", "--json"],
    );
    // A ticket system alone is no ticket (the CLI refuses it).
    assert.ok(!activateRoleArgs({}, role, { justification: "x", ticketSystem: "S" }).some((a) => a.startsWith("--ticket")));
  });

  test("a preset by id, in its own tenant; empty overrides are left out", () => {
    assert.deepEqual(activatePresetArgs({ tenant: "other" }, { id: "p1", tenantId: "t1" }), [
      "activate",
      "--preset-id=p1",
      "--tenant=t1",
      "--yes",
      "--json",
    ]);
    assert.deepEqual(activatePresetArgs({ tenant: "other" }, { id: "p2" }, { justification: "", hours: "2" }), [
      "--tenant=other",
      "activate",
      "--preset-id=p2",
      "--hours=2",
      "--yes",
      "--json",
    ]);
    assert.deepEqual(deactivateArgs(demo, role), ["--demo", "deactivate", `--id=${role.id}`, "--yes", "--json"]);
  });
});

suite("formatting", () => {
  test("durations and time left", () => {
    assert.equal(formatDuration("PT8H"), "8 h");
    assert.equal(formatDuration("PT1H30M"), "1 h 30 min");
    assert.equal(formatDuration("P1D"), "24 h");
    assert.equal(formatDuration("max"), "maximum");
    assert.equal(durationHours("PT4H"), 4);
    const now = new Date("2026-10-30T10:00:00Z");
    assert.equal(formatTimeLeft("2026-10-30T12:39:30Z", now), "2h 39m");
    assert.equal(formatTimeLeft("2026-10-30T10:07:00Z", now), "7m");
    assert.equal(formatTimeLeft("2026-10-30T10:00:30Z", now), "<1m");
    assert.equal(formatTimeLeft("2026-10-30T09:00:00Z", now), "ended");
    assert.equal(formatTimeLeft("2026-10-30T15:05:00Z", now), "5h 05m");
  });

  test("errors: the last error: line, and the sign-in hint for exit 3", () => {
    assert.equal(errorMessage("Activate 1 role\nerror: This role needs a ticket.\n"), "This role needs a ticket.");
    assert.equal(errorMessage("note: x\nsomething broke\n"), "something broke");
    const e = failure({ code: 3, stdout: "", stderr: "error: The Azure CLI is not signed in.\n" });
    assert.equal(e.title, "Pimento: not signed in");
    assert.match(e.message, /az login/);
  });

  test("one toast per result", () => {
    const role = { roleName: "Owner", scopeName: "Contoso Production" } as Role;
    const one = (r: Partial<ChangeResult["results"][0]>, summary = {}): ChangeResult => ({
      results: [{ outcome: "activated", role, ...r }],
      summary,
    });
    assert.equal(describe(one({}, { activated: 1 })).title, "Activated Owner · Contoso Production");
    assert.match(describe(one({ outcome: "submitted", requestId: "dcd43f59-0000" })).message ?? "", /request dcd43f59/);
    const failed = describe(one({ outcome: "failed", code: "ActiveDurationTooShort", message: "too soon" }, { failed: 1 }));
    assert.equal(failed.style, "failure");
    assert.match(failed.message ?? "", /ActiveDurationTooShort: too soon/);
    assert.equal(describe({ results: [], summary: {} }).title, "Nothing to do");
  });
});

suite("against pimento --demo", { skip: bin ? false : "no pimento build: run `swift build` or set PIMENTO_BIN" }, () => {
  test("lists roles, status and presets", async () => {
    const list = await readJSON<RoleList>(bin, listArgs(demo));
    assert.ok(list.roles.length >= 10);
    assert.ok(list.roles.some((r) => r.isActive && r.activeUntil));
    assert.ok(list.roles.every((r) => r.id && r.roleName && r.scopeName));
    const status = await readJSON<RoleList>(bin, statusArgs(demo));
    assert.ok(status.roles.length > 0 && status.roles.every((r) => r.isActive && typeof r.secondsLeft === "number"));
    const presets = await readJSON<PresetList>(bin, presetsArgs(demo));
    assert.deepEqual(
      presets.presets.map((p) => p.name),
      ["Data team", "On-call", "Release day"],
    );
  });

  test("activates exactly the chosen role by id", async () => {
    const list = await readJSON<RoleList>(bin, listArgs(demo));
    const role = list.roles.find((r) => r.roleName === "Contributor" && r.scopeName === "Contoso Staging");
    assert.ok(role);
    const result = await change(bin, activateRoleArgs(demo, role, { justification: "-release", hours: "2" }));
    assert.equal(result.results.length, 1);
    assert.equal(result.results[0].outcome, "activated");
    assert.equal(result.results[0].duration, "PT2H");
    assert.equal(describe(result).title, "Activated Contributor · Contoso Staging");
  });

  test("approval and ticket cases come back readable", async () => {
    const list = await readJSON<RoleList>(bin, listArgs(demo));
    const owner = list.roles.find((r) => r.roleName === "Owner" && r.scopeName === "Contoso Production");
    assert.ok(owner);
    const submitted = await change(bin, activateRoleArgs(demo, owner, { justification: "Rotate", hours: "max" }));
    assert.equal(submitted.results[0].outcome, "submitted");
    assert.match(describe(submitted).title, /^Awaiting approval/);

    const ticket = list.roles.find((r) => r.policy?.requiresTicket && !r.isActive);
    assert.ok(ticket);
    await assert.rejects(change(bin, activateRoleArgs(demo, ticket, { justification: "x" })), (e: unknown) => {
      assert.ok(e instanceof PimentoError);
      assert.equal(e.code, 2);
      assert.match(e.message, /needs a ticket/);
      return true;
    });
    const withTicket = await change(
      bin,
      activateRoleArgs(demo, ticket, { justification: "x", ticketNumber: "CHG-1001", ticketSystem: "ServiceNow" }),
    );
    assert.notEqual(withTicket.results[0].outcome, "failed");
  });

  test("activates a preset and deactivates by id", async () => {
    const presets = await readJSON<PresetList>(bin, presetsArgs(demo));
    const onCall = presets.presets.find((p) => p.name === "On-call");
    assert.ok(onCall);
    const result = await change(bin, activatePresetArgs(demo, onCall));
    assert.equal(result.summary.activated, 2);
    assert.equal(describe(result).title, "2 activated, 1 already done");

    const status = await readJSON<RoleList>(bin, statusArgs(demo));
    const dev = status.roles.find((r) => r.scopeName === "Contoso Development");
    assert.ok(dev);
    const ended = await change(bin, deactivateArgs(demo, dev));
    assert.deepEqual(
      ended.results.map((r) => r.outcome),
      ["deactivated"],
    );
    assert.equal(describe(ended).title, "Deactivated Contributor · Contoso Development");
  });

  test("errors: an unknown preset, a missing binary", async () => {
    await assert.rejects(
      change(bin, activatePresetArgs(demo, { id: "00000000-0000-0000-0000-00000000dead" })),
      (e: unknown) => e instanceof PimentoError && e.code === 1 && /No preset has the id/.test(e.message),
    );
    await assert.rejects(
      run("/nonexistent/pimento", ["version"]),
      (e: unknown) => e instanceof PimentoError && e.code === "ENOENT",
    );
    await assert.rejects(run(undefined, ["version"]), (e: unknown) => e instanceof PimentoError && e.code === "ENOENT");
  });
});
