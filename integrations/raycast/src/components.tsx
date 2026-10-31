import {
  Action,
  ActionPanel,
  Keyboard,
  Alert,
  Color,
  confirmAlert,
  Form,
  Icon,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useState } from "react";
import {
  accessWarning,
  activatePresetArgs,
  activateRoleArgs,
  change,
  deactivateArgs,
  durationHours,
  formatDuration,
  formatTimeLeft,
  presetRoleLines,
  roleLabel,
  scopeTypeLabel,
  secondsLeft,
  type Preset,
  type Role,
} from "./lib/pimento";
import { binary, failToast, settings, showResult } from "./lib/raycast";

// MARK: - Activating a role

function durationChoices(role: Role): { value: string; title: string }[] {
  const max = durationHours(role.policy?.maxDuration ?? role.maxDuration);
  const hours = [1, 2, 4, 8, 12, 24].filter((h) => max === undefined || h < max);
  return [
    ...hours.map((h) => ({ value: String(h), title: h === 1 ? "1 hour" : `${h} hours` })),
    {
      value: "max",
      title:
        max === undefined
          ? "Maximum allowed"
          : `Maximum allowed (${formatDuration(role.policy?.maxDuration ?? role.maxDuration)})`,
    },
  ];
}

export function ActivateRoleForm(props: { role: Role; onDone?: () => void }) {
  const { role } = props;
  const { pop } = useNavigation();
  const needsTicket = role.policy?.requiresTicket === true;
  const [justificationError, setJustificationError] = useState<string>();
  const [ticketError, setTicketError] = useState<string>();
  const choices = durationChoices(role);
  const max = durationHours(role.policy?.maxDuration ?? role.maxDuration);

  async function submit(values: {
    justification: string;
    hours: string;
    ticketNumber?: string;
    ticketSystem?: string;
  }) {
    if (!values.justification.trim()) {
      setJustificationError("Required");
      return;
    }
    const ticket = values.ticketNumber?.trim();
    const system = values.ticketSystem?.trim();
    if (needsTicket && (!ticket || !system)) {
      setTicketError("Its PIM policy requires a ticket number and system");
      return;
    }
    const warning = accessWarning(role);
    if (warning) {
      const ok = await confirmAlert({
        title: `Activate ${roleLabel(role)}?`,
        message: warning,
        icon: { source: Icon.ExclamationMark, tintColor: Color.Red },
        primaryAction: { title: "Activate", style: Alert.ActionStyle.Destructive },
      });
      if (!ok) return;
    }
    const s = settings();
    const toast = await showToast({ style: Toast.Style.Animated, title: `Activating ${roleLabel(role)}…` });
    try {
      const result = await change(
        binary(s),
        activateRoleArgs(s, role, {
          justification: values.justification,
          hours: values.hours,
          ticketNumber: ticket,
          ticketSystem: system,
        }),
      );
      showResult(toast, result);
      props.onDone?.();
      pop();
    } catch (error) {
      failToast(toast, error);
    }
  }

  const notes = [
    role.policy?.requiresApproval
      ? "Needs approval: an approver decides within 24 hours; nothing is active until then."
      : undefined,
    role.policy?.requiresMfa ? "Its policy asks for MFA; sign in with MFA if PIM refuses." : undefined,
    accessWarning(role),
    role.policy?.status && role.policy.status !== "loaded"
      ? "Its PIM policy could not be read: the duration is not capped in advance."
      : undefined,
  ].filter(Boolean);

  return (
    <Form
      navigationTitle={`Activate ${role.roleName}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Activate" icon={Icon.Bolt} onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.Description
        title={role.roleName}
        text={`${role.scopeName} (${scopeTypeLabel(role.scopeType)})${role.group ? `, through ${role.group}` : ""}`}
      />
      <Form.TextField
        id="justification"
        title="Justification"
        placeholder="Why you need the role"
        error={justificationError}
        onChange={() => setJustificationError(undefined)}
        autoFocus
      />
      <Form.Dropdown id="hours" title="Duration" defaultValue={max !== undefined && max <= 8 ? "max" : "8"}>
        {choices.map((c) => (
          <Form.Dropdown.Item key={c.value} value={c.value} title={c.title} />
        ))}
      </Form.Dropdown>
      {needsTicket ? (
        <>
          <Form.TextField
            id="ticketNumber"
            title="Ticket"
            placeholder="CHG-1001"
            error={ticketError}
            onChange={() => setTicketError(undefined)}
          />
          <Form.TextField id="ticketSystem" title="Ticket System" placeholder="ServiceNow" storeValue />
        </>
      ) : null}
      {notes.length > 0 ? <Form.Description text={notes.join("\n")} /> : null}
    </Form>
  );
}

// MARK: - Deactivating

export async function deactivate(role: Role, onDone?: () => void): Promise<void> {
  const ok = await confirmAlert({
    title: `Deactivate ${roleLabel(role)}?`,
    message: "Access through this role ends now. PIM ends an activation only after its first 5 minutes.",
    primaryAction: { title: "Deactivate", style: Alert.ActionStyle.Destructive },
  });
  if (!ok) return;
  const s = settings();
  const toast = await showToast({ style: Toast.Style.Animated, title: `Deactivating ${roleLabel(role)}…` });
  try {
    showResult(toast, await change(binary(s), deactivateArgs(s, role)));
    onDone?.();
  } catch (error) {
    failToast(toast, error);
  }
}

// MARK: - Presets

export async function activatePreset(
  preset: Preset,
  input: { justification?: string; hours?: string } = {},
  onDone?: () => void,
): Promise<boolean> {
  const justification = input.justification?.trim() || preset.justification;
  const duration = input.hours
    ? formatDuration(input.hours === "max" ? "max" : `PT${input.hours}H`)
    : formatDuration(preset.duration);
  const ok = await confirmAlert({
    title: `Activate preset “${preset.name}”?`,
    message: [
      ...presetRoleLines(preset),
      "",
      `Justification: ${justification}`,
      `Duration: ${duration ?? "8 h"} (capped at each role's maximum)`,
    ].join("\n"),
    primaryAction: { title: "Activate" },
  });
  if (!ok) return false;
  const s = settings();
  const toast = await showToast({ style: Toast.Style.Animated, title: `Activating “${preset.name}”…` });
  try {
    showResult(toast, await change(binary(s), activatePresetArgs(s, preset, input)));
    onDone?.();
    return true;
  } catch (error) {
    failToast(toast, error);
    return false;
  }
}

export function ActivatePresetForm(props: { preset: Preset; onDone?: () => void }) {
  const { preset } = props;
  const { pop } = useNavigation();
  const [error, setError] = useState<string>();
  return (
    <Form
      navigationTitle={`Activate “${preset.name}”`}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Activate Preset"
            icon={Icon.Bolt}
            onSubmit={async (values: { justification: string; hours: string }) => {
              if (!values.justification.trim() && !preset.justification) {
                setError("Required: the preset has no justification");
                return;
              }
              const done = await activatePreset(
                preset,
                {
                  justification: values.justification,
                  hours: values.hours === "preset" ? undefined : values.hours,
                },
                props.onDone,
              );
              if (done) pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.Description title={preset.name} text={presetRoleLines(preset).join("\n")} />
      <Form.TextField
        id="justification"
        title="Justification"
        placeholder={preset.justification ?? "Why you need the roles"}
        info={preset.justification ? "Empty: the preset's justification" : undefined}
        error={error}
        onChange={() => setError(undefined)}
        autoFocus
      />
      <Form.Dropdown id="hours" title="Duration" defaultValue="preset">
        <Form.Dropdown.Item value="preset" title={`The preset's (${formatDuration(preset.duration) ?? "8 h"})`} />
        {[1, 2, 4, 8].map((h) => (
          <Form.Dropdown.Item key={h} value={String(h)} title={h === 1 ? "1 hour" : `${h} hours`} />
        ))}
        <Form.Dropdown.Item value="max" title="Maximum allowed" />
      </Form.Dropdown>
    </Form>
  );
}

// MARK: - List rows

export function timeLeftTag(role: Role, now: Date): List.Item.Accessory {
  const left = secondsLeft(role, now);
  const text = role.activeUntil ? (formatTimeLeft(role.activeUntil, now) ?? "") : "no end";
  const color =
    left === undefined ? Color.Green : left < 15 * 60 ? Color.Red : left < 60 * 60 ? Color.Orange : Color.Green;
  return {
    tag: { value: text, color },
    tooltip: role.activeUntil ? `Active until ${new Date(role.activeUntil).toLocaleString()}` : "Active, no end",
  };
}

export function roleAccessories(role: Role, now: Date): List.Item.Accessory[] {
  const a: List.Item.Accessory[] = [];
  const warning = accessWarning(role);
  if (warning) a.push({ tag: { value: role.isOwner ? "Owner" : "Grants access", color: Color.Red }, tooltip: warning });
  if (role.policy?.requiresApproval) a.push({ icon: Icon.TwoPeople, tooltip: "Needs approval" });
  if (role.policy?.requiresTicket) a.push({ icon: Icon.Receipt, tooltip: "Needs a ticket" });
  if (role.group) a.push({ icon: Icon.PersonLines, tooltip: `Through ${role.group}` });
  a.push({ text: scopeTypeLabel(role.scopeType) });
  if (role.isActive) a.push(timeLeftTag(role, now));
  else {
    const max = formatDuration(role.policy?.maxDuration ?? role.maxDuration);
    if (max) a.push({ text: `max ${max}`, tooltip: "Longest activation its policy allows" });
  }
  return a;
}

export function CopyActions(props: { role: Role }) {
  return (
    <ActionPanel.Section>
      <Action.CopyToClipboard title="Copy Role ID" content={props.role.id} shortcut={Keyboard.Shortcut.Common.Copy} />
      <Action.CopyToClipboard
        title="Copy Scope"
        content={props.role.scope}
        shortcut={Keyboard.Shortcut.Common.CopyPath}
      />
    </ActionPanel.Section>
  );
}

/** Re-renders every 30 seconds so the time left stays current. */
export function useNow(intervalMs = 30_000): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), intervalMs);
    return () => clearInterval(timer);
  }, [intervalMs]);
  return now;
}
