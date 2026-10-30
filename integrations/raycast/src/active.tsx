import { Action, ActionPanel, Keyboard, Color, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { CopyActions, deactivate, timeLeftTag, useNow } from "./components";
import {
  formatClock,
  grantsAccess,
  PimentoError,
  readJSON,
  scopeTypeLabel,
  statusArgs,
  type RoleList,
} from "./lib/pimento";
import { binary, demoNote, settings, showError } from "./lib/raycast";

export default function Command() {
  const s = settings();
  const { data, isLoading, error, revalidate } = usePromise(() => readJSON<RoleList>(binary(s), statusArgs(s)), [], {
    onError: (e) => showError(e, "Could not read active roles"),
  });
  const now = useNow();
  // `pimento status` sorts soonest-expiring first; drop what ended since.
  const roles = (data?.roles ?? []).filter((r) => !r.activeUntil || Date.parse(r.activeUntil) > now.getTime());

  return (
    <List isLoading={isLoading} navigationTitle={s.demo ? "Active PIM Roles (Demo)" : "Active PIM Roles"}>
      {error ? (
        <List.EmptyView
          icon={{ source: Icon.Warning, tintColor: Color.Red }}
          title={error instanceof PimentoError ? error.title : "Could not read active roles"}
          description={error.message}
          actions={
            <ActionPanel>
              <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={revalidate} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          icon={Icon.Moon}
          title="No active roles"
          description="Activate one with Search PIM Roles or a preset."
        />
      )}
      <List.Section title="Active" subtitle={s.demo ? demoNote : (data?.user?.upn ?? data?.user?.name)}>
        {roles.map((role) => (
          <List.Item
            key={role.id}
            title={role.roleName}
            subtitle={role.scopeName}
            keywords={[role.scopeType, role.group ?? ""].filter(Boolean)}
            icon={{ source: Icon.Clock, tintColor: Color.Green }}
            accessories={[
              ...(grantsAccess(role)
                ? [{ tag: { value: role.isOwner ? "Owner" : "Grants access", color: Color.Red } }]
                : []),
              { text: scopeTypeLabel(role.scopeType) },
              ...(role.activeUntil ? [{ text: `until ${formatClock(role.activeUntil)}` }] : []),
              timeLeftTag(role, now),
            ]}
            actions={
              <ActionPanel>
                <Action
                  title="Deactivate"
                  icon={Icon.Stop}
                  style={Action.Style.Destructive}
                  onAction={() => deactivate(role, revalidate)}
                />
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  shortcut={Keyboard.Shortcut.Common.Refresh}
                  onAction={revalidate}
                />
                <CopyActions role={role} />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
