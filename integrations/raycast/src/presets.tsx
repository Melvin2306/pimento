import { Action, ActionPanel, Keyboard, Color, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { activatePreset, ActivatePresetForm } from "./components";
import {
  PimentoError,
  presetCommand,
  presetDetail,
  presetRoleLines,
  presetsArgs,
  presetSummary,
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
          <PresetItem key={preset.id} preset={preset} />
        ))}
      </List.Section>
    </List>
  );
}

function PresetItem(props: { preset: Preset }) {
  const { preset } = props;
  const form = <ActivatePresetForm preset={preset} />;
  return (
    <List.Item
      title={preset.name}
      subtitle={presetSummary(preset)}
      keywords={presetRoleLines(preset)}
      icon={Icon.Star}
      detail={
        <List.Item.Detail
          metadata={
            <List.Item.Detail.Metadata>
              {presetDetail(preset).map((f, i) => (
                <List.Item.Detail.Metadata.Label key={i} title={f.title} text={f.text} />
              ))}
            </List.Item.Detail.Metadata>
          }
        />
      }
      actions={
        <ActionPanel>
          {preset.justification ? (
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
            content={presetCommand(preset)}
            shortcut={Keyboard.Shortcut.Common.Copy}
          />
        </ActionPanel>
      }
    />
  );
}
