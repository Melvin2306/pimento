import { Action, ActionPanel, Keyboard, Color, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { activatePreset, ActivatePresetForm, presetRoleLines, presetSummary } from "./components";
import {
  formatDuration,
  PimentoError,
  presetIsAmbiguous,
  presetsArgs,
  readJSON,
  type Preset,
  type PresetList,
} from "./lib/pimento";
import { binary, demoNote, settings, showError } from "./lib/raycast";

export default function Command() {
  const s = settings();
  const { data, isLoading, error, revalidate } = usePromise(() => readJSON<PresetList>(binary(s), presetsArgs(s)), [], {
    onError: (e) => showError(e, "Could not read presets"),
  });
  const presets = data?.presets ?? [];

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={presets.length > 0}
      navigationTitle={s.demo ? "Pimento Presets (Demo)" : "Pimento Presets"}
      searchBarPlaceholder="Filter presets"
    >
      {error ? (
        <List.EmptyView
          icon={{ source: Icon.Warning, tintColor: Color.Red }}
          title={error instanceof PimentoError ? error.title : "Could not read presets"}
          description={error.message}
          actions={
            <ActionPanel>
              <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={revalidate} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          icon={Icon.Star}
          title="No presets yet"
          description="Save one in the Pimento app, or with `pimento presets save NAME FILTER… --role NAME`."
        />
      )}
      <List.Section title="Presets" subtitle={s.demo ? demoNote : undefined}>
        {presets.map((preset) => (
          <PresetItem key={preset.id} preset={preset} ambiguous={presetIsAmbiguous(preset, presets)} />
        ))}
      </List.Section>
    </List>
  );
}

function PresetItem(props: { preset: Preset; ambiguous: boolean }) {
  const { preset, ambiguous } = props;
  const markdown = [
    ...(ambiguous
      ? [
          "> Another preset is also named “" + preset.name + "”. This one has no tenant, so `--preset` would pick",
          "> the other one in its tenant. Rename one in Pimento to activate it here.",
          "",
        ]
      : []),
    `## ${preset.name}`,
    "",
    ...presetRoleLines(preset).map((l) => `- ${l}`),
    "",
    preset.justification
      ? `**Justification:** ${preset.justification}`
      : "_No justification saved: you are asked for one._",
    "",
    `**Duration:** ${formatDuration(preset.duration) ?? "8 h (default)"}, capped at each role's maximum`,
    ...(preset.ticketSystem ? ["", `**Ticket system:** ${preset.ticketSystem}`] : []),
  ].join("\n");
  const form = <ActivatePresetForm preset={preset} />;
  return (
    <List.Item
      title={preset.name}
      subtitle={presetSummary(preset)}
      keywords={presetRoleLines(preset)}
      icon={Icon.Star}
      detail={<List.Item.Detail markdown={markdown} />}
      actions={
        <ActionPanel>
          {ambiguous ? null : preset.justification ? (
            <>
              <Action title="Activate Preset" icon={Icon.Bolt} onAction={() => activatePreset(preset)} />
              <Action.Push
                title="Activate with Justification…"
                icon={Icon.Pencil}
                shortcut={{ modifiers: ["cmd"], key: "return" }}
                target={form}
              />
            </>
          ) : (
            <Action.Push title="Activate Preset…" icon={Icon.Bolt} target={form} />
          )}
          <Action.CopyToClipboard
            title="Copy Command"
            content={`pimento activate --preset ${JSON.stringify(preset.name)}`}
            shortcut={Keyboard.Shortcut.Common.Copy}
          />
        </ActionPanel>
      }
    />
  );
}
