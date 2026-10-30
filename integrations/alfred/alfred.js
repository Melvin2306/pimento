// JXA (osascript -l JavaScript), no other runtime: turns pimento's JSON into
// Alfred's Script Filter JSON and run results into a notification.
//
//   alfred.js items ROLES.json PRESETS.json QUERY DEFAULT_HOURS [demo]
//   alfred.js error CODE STDERR.txt BINARY
//   alfred.js result CODE RESULT.json STDERR.txt LABEL
//   alfred.js notfound [result]
//   alfred.js usage result ACTION

ObjC.import("Foundation");

function readText(path) {
  if (!path) return "";
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s.isNil() ? "" : s.js;
}

function readJSON(path) {
  const text = readText(path);
  if (!text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch (e) {
    return null;
  }
}

// MARK: - Formatting (as in the CLI)

function durationHours(iso) {
  const m = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$/i.exec(iso || "");
  if (!m) return undefined;
  return Number(m[1] || 0) * 24 + Number(m[2] || 0) + Number(m[3] || 0) / 60;
}

function formatDuration(iso) {
  if (!iso) return undefined;
  if (String(iso).toLowerCase() === "max") return "the maximum";
  const h = durationHours(iso);
  if (h === undefined) return iso;
  if (h < 1) return Math.round(h * 60) + " min";
  return Number.isInteger(h) ? h + " h" : h.toFixed(1) + " h";
}

function hoursLabel(hours) {
  return hours === "max" ? "the maximum" : hours + " h";
}

function timeLeft(until, now) {
  if (!until) return "no end";
  const seconds = Math.floor((Date.parse(until) - now.getTime()) / 1000);
  if (isNaN(seconds)) return "?";
  if (seconds <= 0) return "ended";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 1) return "<1m";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h === 0 ? m + "m" : h + "h " + (m < 10 ? "0" : "") + m + "m";
}

function clock(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  const pad = (n) => (n < 10 ? "0" : "") + n;
  return pad(d.getHours()) + ":" + pad(d.getMinutes());
}

function scopeTypeLabel(t) {
  switch (String(t || "").toLowerCase()) {
    case "subscription":
      return "Subscription";
    case "resourcegroup":
      return "Resource group";
    case "managementgroup":
      return "Management group";
    default:
      return "Resource";
  }
}

function label(role) {
  return role.roleName + (role.isOwner ? " (!)" : "") + " · " + role.scopeName;
}

/** A short, stable handle for one row: the start of its eligibility schedule GUID. */
function token(role) {
  const id = role.eligibilityScheduleId || role.id || "";
  return id.split("/").pop().slice(0, 8).toLowerCase();
}

// MARK: - The query

/** "WORDS > JUSTIFICATION": words narrow the list; "@token" picks one role. */
function parseQuery(query) {
  const at = query.indexOf(">");
  const filter = at < 0 ? query : query.slice(0, at);
  const justification = at < 0 ? "" : query.slice(at + 1).trim();
  const words = filter.toLowerCase().split(/\s+/).filter(Boolean);
  const tokens = words.filter((w) => /^@[0-9a-f]{4,}$/.test(w)).map((w) => w.slice(1));
  return {
    arrow: at >= 0,
    filter: filter.trim(),
    words: words.filter((w) => !w.startsWith("@") && w !== "·"),
    tokens,
    justification,
  };
}

function matches(haystack, words) {
  const h = haystack.toLowerCase();
  return words.every((w) => h.indexOf(w) >= 0);
}

// MARK: - Items

function presetItem(p, q, defaultHours) {
  const roles = (p.roles || []).length;
  const rules = (p.match || []).length;
  const what = [roles === 1 ? "1 role" : roles + " roles"].concat(rules ? [rules === 1 ? "1 rule" : rules + " rules"] : []).join(" + ");
  const justification = q.justification || p.justification || "";
  const duration = formatDuration(p.duration) || hoursLabel(defaultHours);
  const vars = {
    pim_action: "preset",
    pim_preset: p.name,
    pim_preset_tenant: p.tenantId || "",
    pim_justification: q.justification,
    pim_hours: "",
    pim_label: "preset " + p.name,
  };
  const lines = (p.roles || [])
    .map((r) => (r.roleName || "Role") + " · " + (r.scopeName || r.scope))
    .concat((p.match || []).map((m) => "Rule: " + (m.roles || []).concat(m.filters || []).join(", ")));
  return {
    uid: "preset:" + p.id,
    title: "Preset: " + p.name,
    subtitle: justification
      ? "↩ Activate " + what + " for " + duration + ": " + justification
      : "Type > and a justification to activate its " + what,
    valid: Boolean(justification),
    autocomplete: p.name + " > ",
    icon: { path: "icon.png" },
    variables: vars,
    mods: {
      cmd: {
        valid: Boolean(justification),
        subtitle: justification ? "⌘↩ Activate " + what + " for the maximum each role allows" : "Type > and a justification first",
        variables: Object.assign({}, vars, { pim_hours: "max" }),
      },
    },
    text: { copy: 'pimento activate --preset "' + p.name + '"', largetype: lines.join("\n") },
  };
}

function eligibleItem(r, q, defaultHours) {
  const max = formatDuration((r.policy && r.policy.maxDuration) || r.maxDuration);
  const needsTicket = Boolean(r.policy && r.policy.requiresTicket);
  const needsApproval = Boolean(r.policy && r.policy.requiresApproval);
  const facts = [scopeTypeLabel(r.scopeType)]
    .concat(max ? ["max " + max] : [])
    .concat(r.group ? ["via " + r.group] : [])
    .concat(needsApproval ? ["needs approval"] : []);
  const vars = {
    pim_action: "activate",
    pim_id: r.id,
    pim_justification: q.justification,
    pim_hours: defaultHours,
    pim_label: r.roleName + " · " + r.scopeName,
  };
  let subtitle;
  let valid = false;
  if (needsTicket) {
    subtitle = facts.join(" · ") + " · needs a ticket: use the Pimento app or pimento activate --ticket";
  } else if (q.justification) {
    subtitle = "↩ Activate for " + hoursLabel(defaultHours) + (max ? " (at most " + max + ")" : "") + ": " + q.justification;
    valid = true;
  } else if (q.arrow) {
    subtitle = "Type the justification, then ↩ to activate for " + hoursLabel(defaultHours) + " (⌘↩ for the maximum)";
  } else {
    subtitle = facts.join(" · ") + " · ↩ then type a justification";
  }
  return {
    uid: "role:" + r.id,
    title: label(r),
    subtitle,
    valid,
    autocomplete: label(r) + " @" + token(r) + " > ",
    icon: { path: "icon.png" },
    variables: vars,
    mods: {
      cmd: {
        valid,
        subtitle: valid ? "⌘↩ Activate for the maximum its policy allows" + (max ? " (" + max + ")" : "") : subtitle,
        variables: Object.assign({}, vars, { pim_hours: "max" }),
      },
      alt: { valid: false, subtitle: "Not active" },
    },
    text: { copy: r.id, largetype: label(r) + "\n" + r.scope },
  };
}

function activeItem(r, now) {
  const until = clock(r.activeUntil);
  return {
    uid: "role:" + r.id,
    title: label(r),
    subtitle:
      "Active · " +
      timeLeft(r.activeUntil, now) +
      " left" +
      (until ? " (until " + until + ")" : "") +
      " · " +
      scopeTypeLabel(r.scopeType) +
      " · ⌥↩ deactivate",
    valid: false,
    autocomplete: label(r) + " @" + token(r) + " ",
    icon: { path: "icon.png" },
    mods: {
      alt: {
        valid: true,
        subtitle: "⌥↩ Deactivate now (PIM allows it after the first 5 minutes)",
        variables: { pim_action: "deactivate", pim_id: r.id, pim_label: r.roleName + " · " + r.scopeName },
      },
      cmd: { valid: false, subtitle: "Already active" },
    },
    text: { copy: r.id, largetype: label(r) + "\n" + r.scope },
  };
}

function items(rolesPath, presetsPath, query, defaultHours, demo) {
  const list = readJSON(rolesPath) || { roles: [] };
  const presetList = readJSON(presetsPath) || { presets: [] };
  const q = parseQuery(query || "");
  const hours = /^(max|[1-9]|1[0-9]|2[0-4])$/.test(String(defaultHours)) ? String(defaultHours) : "8";
  const now = new Date();
  const out = [];

  // A preset named exactly (after ↩ autocompleted it) is the only result.
  const exact = (presetList.presets || []).filter((p) => p.name.toLowerCase() === q.filter.toLowerCase());
  if (exact.length === 1 && q.tokens.length === 0) {
    out.push(presetItem(exact[0], q, hours));
  } else {
    const roles = (list.roles || []).filter((r) =>
      q.tokens.length > 0
        ? q.tokens.some((t) => token(r).startsWith(t))
        : matches(
            [r.roleName, r.scopeName, scopeTypeLabel(r.scopeType), r.group || "", r.isActive ? "active" : "eligible"].join(" "),
            q.words,
          ),
    );
    if (q.tokens.length === 0) {
      for (const p of presetList.presets || []) {
        const hay = ["preset", p.name].concat((p.roles || []).map((r) => (r.roleName || "") + " " + (r.scopeName || ""))).join(" ");
        if (matches(hay, q.words)) out.push(presetItem(p, q, hours));
      }
    }
    const active = roles
      .filter((r) => r.isActive)
      .sort((a, b) => Date.parse(a.activeUntil || "9999") - Date.parse(b.activeUntil || "9999"));
    for (const r of active) out.push(activeItem(r, now));
    for (const r of roles.filter((r) => !r.isActive)) out.push(eligibleItem(r, q, hours));
  }

  if (out.length === 0) {
    out.push({
      title: "No matching role or preset",
      subtitle: q.words.length || q.tokens.length ? "Try fewer words" : "pimento lists no eligible roles in this tenant",
      valid: false,
      icon: { path: "icon.png" },
    });
  }
  if (demo === "demo") {
    out.push({
      title: "Demo mode",
      subtitle: "Synthetic data (pimento --demo): every command starts from the demo data, so changes do not carry over",
      valid: false,
      icon: { path: "icon.png" },
    });
  }
  // Keep pimento's order (presets, then active, then eligible) rather than Alfred's learning.
  return JSON.stringify({ skipknowledge: true, items: out });
}

// MARK: - Errors and results

function errorMessage(stderr) {
  const lines = stderr
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  const error = lines
    .slice()
    .reverse()
    .find((l) => l.toLowerCase().startsWith("error:"));
  return (error || lines[lines.length - 1] || "").replace(/^error:\s*/i, "");
}

function errorTitle(code) {
  switch (code) {
    case 1:
      return "It did not work";
    case 2:
      return "Not possible as asked";
    case 3:
      return "Not signed in";
    case 4:
      return "Timed out";
    case 126:
    case 127:
      return "pimento could not be run";
    default:
      return "pimento failed (exit code " + code + ")";
  }
}

function failureText(code, stderr) {
  let message = errorMessage(stderr) || "No details on stderr.";
  if (code === 3 && !/az login|pimento login/.test(message)) message += " Run az login or pimento login in a terminal.";
  return message;
}

function error(code, stderrPath, binary) {
  const c = Number(code);
  const message = c === 126 || c === 127 ? binary + " is missing or not executable: set pimento_path in the workflow's configuration." : failureText(c, readText(stderrPath));
  return JSON.stringify({
    items: [
      {
        title: "Pimento: " + errorTitle(c),
        subtitle: message,
        valid: false,
        icon: { path: "icon.png" },
        text: { copy: message, largetype: message },
      },
    ],
  });
}

function notification(title, text) {
  return JSON.stringify({ alfredworkflow: { arg: text, variables: { pim_title: title } } });
}

function result(code, resultPath, stderrPath, what) {
  const c = Number(code);
  const doc = readJSON(resultPath);
  if (!doc || !Array.isArray(doc.results)) {
    return notification("Pimento: " + errorTitle(c), failureText(c, readText(stderrPath)));
  }
  const s = doc.summary || {};
  const failed = doc.results.filter((r) => r.outcome === "failed");
  const one = doc.results.length === 1 ? doc.results[0] : null;
  const parts = [];
  if (s.activated) parts.push(s.activated + " activated");
  if (s.deactivated) parts.push(s.deactivated + " deactivated");
  if (s.submitted) parts.push(s.submitted + " awaiting approval");
  if (s.skipped) parts.push(s.skipped + " already done");
  if (s.failed) parts.push(s.failed + " failed");
  if (doc.missing && doc.missing.length) parts.push(doc.missing.length + " no longer eligible");
  if (failed.length > 0) {
    const f = failed[0];
    const at = clock(f.possibleAt);
    const why = [f.code, f.message].filter(Boolean).join(": ") + (at ? " (possible from " + at + ")" : "");
    const who = f.role ? f.role.roleName + " · " + f.role.scopeName + ": " : "";
    return notification("Pimento: " + (one ? "failed" : parts.join(", ")), who + (why || "failed"));
  }
  if (one && one.role) {
    const name = one.role.roleName + " · " + one.role.scopeName;
    switch (one.outcome) {
      case "activated":
        return notification("Pimento: activated", name + (one.until ? " until " + clock(one.until) : ""));
      case "submitted":
        return notification(
          "Pimento: awaiting approval",
          name + ": nothing is active until an approver decides" + (one.requestId ? " (request " + one.requestId.slice(0, 8) + ")" : ""),
        );
      case "deactivated":
        return notification("Pimento: deactivated", name);
      case "skipped":
        return notification("Pimento: nothing to do", name + ": " + (one.message || "already active"));
    }
  }
  return notification("Pimento: " + (what || "done"), parts.length ? parts.join(", ") : "Nothing to do");
}

function run(argv) {
  const mode = argv[0];
  switch (mode) {
    case "items":
      return items(argv[1], argv[2], argv[3], argv[4], argv[5]);
    case "error":
      return error(argv[1], argv[2], argv[3]);
    case "result":
      return result(argv[1], argv[2], argv[3], argv[4]);
    case "notfound": {
      const text =
        "Install the CLI (README: Install the command-line tool) or set pimento_path in the workflow's configuration. Looked in ~/.local/bin, PATH, /opt/homebrew/bin, /usr/local/bin and Pimento.app.";
      if (argv[1] === "result") return notification("Pimento: pimento not found", text);
      return JSON.stringify({
        items: [{ title: "Pimento: pimento not found", subtitle: text, valid: false, icon: { path: "icon.png" } }],
      });
    }
    case "usage":
      return notification("Pimento: nothing to do", "Unknown action “" + (argv[2] || "") + "”.");
    default:
      return JSON.stringify({ items: [{ title: "alfred.js: unknown mode " + mode, valid: false }] });
  }
}
