import { getPreferenceValues, showToast, Toast } from "@raycast/api";
import { describe, findPimento, PimentoError, type ChangeResult, type Settings } from "./pimento";

interface Preferences {
  pimentoPath?: string;
  demoMode?: boolean;
  tenant?: string;
}

export function settings(): Settings {
  const p = getPreferenceValues<Preferences>();
  return { pimentoPath: p.pimentoPath, demo: Boolean(p.demoMode), tenant: p.tenant };
}

export function binary(s: Settings = settings()): string | undefined {
  return findPimento(s.pimentoPath);
}

/** A toast for anything `run` / `readJSON` / `change` threw. */
export async function showError(error: unknown, fallbackTitle = "Pimento failed"): Promise<void> {
  if (error instanceof PimentoError) {
    await showToast({ style: Toast.Style.Failure, title: error.title, message: error.message });
    return;
  }
  await showToast({
    style: Toast.Style.Failure,
    title: fallbackTitle,
    message: error instanceof Error ? error.message : String(error),
  });
}

/** Turns an animated toast into the result of an activate/deactivate run. */
export function showResult(toast: Toast, result: ChangeResult): void {
  const d = describe(result);
  toast.style = d.style === "success" ? Toast.Style.Success : Toast.Style.Failure;
  toast.title = d.title;
  toast.message = d.message;
}

export function failToast(toast: Toast, error: unknown): void {
  toast.style = Toast.Style.Failure;
  if (error instanceof PimentoError) {
    toast.title = error.title;
    toast.message = error.message;
  } else {
    toast.title = "Pimento failed";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}

export const demoNote =
  "Demo mode: every command starts from the demo data, so changes do not carry over to the next one.";
