// Platform bridge: real files and dialogs under Tauri, browser fallbacks
// otherwise (so the UI can be developed and screenshot-tested in a browser).

export interface OpenedFile {
  path: string | null; // null in the browser fallback
  name: string;
  text: string;
}

export const isTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
export const isMac = typeof navigator !== "undefined" && /Mac/.test(navigator.platform);
export const modKey = isMac ? "⌘" : "Ctrl+";

const FILTERS = [
  { name: "Documents", extensions: ["md", "markdown", "fountain", "txt"] },
  { name: "Markdown", extensions: ["md", "markdown"] },
  { name: "Fountain", extensions: ["fountain"] },
  { name: "Plain Text", extensions: ["txt"] },
];

export function baseName(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

export async function readFile(path: string): Promise<OpenedFile> {
  const text = await invoke<string>("read_text", { path });
  return { path, name: baseName(path), text };
}

export async function openFile(): Promise<OpenedFile | null> {
  if (isTauri) {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const path = await open({ multiple: false, directory: false, filters: FILTERS });
    return typeof path === "string" ? readFile(path) : null;
  }
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".md,.markdown,.fountain,.txt,text/plain";
    input.onchange = async () => {
      const file = input.files?.[0];
      resolve(file ? { path: null, name: file.name, text: await file.text() } : null);
    };
    input.click();
  });
}

/** Write to `path`; returns false if the write failed (an error was shown). */
export async function writeFile(path: string, text: string): Promise<boolean> {
  try {
    await invoke("write_text", { path, text });
    return true;
  } catch (error) {
    await showError(`Could not save ${baseName(path)}: ${String(error)}`);
    return false;
  }
}

/** Ask where to save. Browser fallback downloads the file and returns null. */
export async function chooseSavePath(suggestedName: string, text: string): Promise<string | null> {
  if (isTauri) {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return (await save({ defaultPath: suggestedName, filters: FILTERS })) ?? null;
  }
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: suggestedName });
  a.click();
  URL.revokeObjectURL(url);
  return null;
}

export async function confirmDiscard(name: string): Promise<boolean> {
  const message = `“${name}” has unsaved changes. Discard them?`;
  if (isTauri) {
    const { ask } = await import("@tauri-apps/plugin-dialog");
    return ask(message, { title: "FocusEdit", kind: "warning", okLabel: "Discard", cancelLabel: "Keep Editing" });
  }
  return window.confirm(message);
}

export async function showError(message: string): Promise<void> {
  if (isTauri) {
    const { message: show } = await import("@tauri-apps/plugin-dialog");
    await show(message, { title: "FocusEdit", kind: "error" });
  } else {
    window.alert(message);
  }
}

export async function setWindowTitle(title: string): Promise<void> {
  document.title = title;
  if (isTauri) {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    await getCurrentWindow().setTitle(title);
  }
}

export async function toggleFullscreen(): Promise<void> {
  if (isTauri) {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    const win = getCurrentWindow();
    await win.setFullscreen(!(await win.isFullscreen()));
  } else if (document.fullscreenElement) {
    await document.exitFullscreen();
  } else {
    await document.documentElement.requestFullscreen();
  }
}

/** File passed on the command line or by "Open with" (Tauri only). */
export async function startupFile(): Promise<string | null> {
  return isTauri ? invoke<string | null>("startup_file") : null;
}

/** Run `guard` before the window closes; it returns false to keep the window open. */
export async function onCloseRequested(guard: () => Promise<boolean>): Promise<void> {
  if (isTauri) {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    await getCurrentWindow().onCloseRequested(async (event) => {
      if (!(await guard())) event.preventDefault();
    });
  } else {
    window.addEventListener("beforeunload", (event) => {
      // Browsers only allow a generic prompt here.
      if ((window as unknown as { focusEditDirty?: boolean }).focusEditDirty) event.preventDefault();
    });
  }
}

/** Close the window; the close guard (unsaved changes) still runs. */
export async function closeWindow(): Promise<void> {
  if (isTauri) {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    await getCurrentWindow().close();
  } else {
    window.close();
  }
}
