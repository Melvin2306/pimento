import { Action, ActionPanel, Keyboard, Color, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { ActivateRoleForm, CopyActions, deactivate, roleAccessories, useNow } from "./components";
import { listArgs, PimentoError, readJSON, type Role, type RoleList } from "./lib/pimento";
import { binary, demoNote, settings, showError } from "./lib/raycast";

export default function Command() {
  const s = settings();
  const { data, isLoading, error, revalidate } = usePromise(() => readJSON<RoleList>(binary(s), listArgs(s)), [], {
    onError: (e) => showError(e, "Could not list roles"),
  });
  const now = useNow();
  const roles = data?.roles ?? [];
  const active = roles
    .filter((r) => r.isActive)
    .sort((a, b) => Date.parse(a.activeUntil ?? "9999") - Date.parse(b.activeUntil ?? "9999"));
  const eligible = roles.filter((r) => !r.isActive);
  const signedIn = data?.user?.upn ?? data?.user?.name;

  return (
    <List
      isLoading={isLoading}
      navigationTitle={s.demo ? "Pimento Roles (Demo)" : "Pimento Roles"}
      searchBarPlaceholder="Filter by role, resource or group"
    >
      {error ? (
        <List.EmptyView
          icon={{ source: Icon.Warning, tintColor: Color.Red }}
          title={error instanceof PimentoError ? error.title : "Could not list roles"}
          description={error.message}
          actions={
            <ActionPanel>
              <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={revalidate} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          icon={Icon.Key}
          title="No eligible roles"
          description="PIM lists no eligibilities for you in this tenant."
        />
      )}
      <List.Section title="Active" subtitle={signedIn}>
        {active.map((role) => (
          <RoleItem key={role.id} role={role} now={now} onChange={revalidate} />
        ))}
      </List.Section>
      <List.Section title="Eligible" subtitle={s.demo ? demoNote : undefined}>
        {eligible.map((role) => (
          <RoleItem key={role.id} role={role} now={now} onChange={revalidate} />
        ))}
      </List.Section>
    </List>
  );
}

function RoleItem(props: { role: Role; now: Date; onChange: () => void }) {
  const { role, now, onChange } = props;
  return (
    <List.Item
      title={role.roleName}
      subtitle={role.scopeName}
      keywords={[role.scopeType, role.group ?? "", role.membership, role.isActive ? "active" : "eligible"].filter(
        Boolean,
      )}
      icon={
        role.isActive
          ? { source: Icon.CheckCircle, tintColor: Color.Green }
          : { source: Icon.Circle, tintColor: Color.SecondaryText }
      }
      accessories={roleAccessories(role, now)}
      actions={
        <ActionPanel>
          {role.isActive ? (
            <Action
              title="Deactivate"
              icon={Icon.Stop}
              style={Action.Style.Destructive}
              onAction={() => deactivate(role, onChange)}
            />
          ) : (
            <Action.Push
              title="Activate…"
              icon={Icon.Bolt}
              target={<ActivateRoleForm role={role} onDone={onChange} />}
            />
          )}
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={Keyboard.Shortcut.Common.Refresh}
            onAction={onChange}
          />
          <CopyActions role={role} />
        </ActionPanel>
      }
    />
  );
}
