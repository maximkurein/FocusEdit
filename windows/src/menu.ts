// A small pop-up menu under a toolbar button: used for recent files and export.

export interface MenuItem {
  label: string;
  /** Dimmed text after the label (a folder, a shortcut). */
  detail?: string;
  disabled?: boolean;
  /** A section title, not clickable. */
  heading?: boolean;
  separator?: boolean;
  run?: () => void;
}

let close: (() => void) | null = null;

/** Closes the open menu; true when there was one. */
export function closeMenu(): boolean {
  const wasOpen = close !== null;
  close?.();
  return wasOpen;
}

export function showMenu(anchor: HTMLElement, items: MenuItem[]): void {
  closeMenu();
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.setAttribute("role", "menu");

  const buttons: HTMLButtonElement[] = [];
  for (const item of items) {
    if (item.separator) {
      const hr = document.createElement("div");
      hr.className = "menu-sep";
      menu.append(hr);
      continue;
    }
    if (item.heading) {
      const h = document.createElement("div");
      h.className = "menu-heading";
      h.textContent = item.label;
      menu.append(h);
      continue;
    }
    const button = document.createElement("button");
    button.type = "button";
    button.className = "menu-item";
    button.setAttribute("role", "menuitem");
    button.disabled = item.disabled ?? false;
    const label = document.createElement("span");
    label.className = "menu-label";
    label.textContent = item.label;
    button.append(label);
    if (item.detail) {
      const detail = document.createElement("span");
      detail.className = "menu-detail";
      detail.textContent = item.detail;
      button.append(detail);
    }
    button.addEventListener("click", () => {
      closeMenu();
      item.run?.();
    });
    buttons.push(button);
    menu.append(button);
  }
  document.body.append(menu);

  // Under the button, right edges aligned, kept inside the window.
  const a = anchor.getBoundingClientRect();
  const width = menu.offsetWidth;
  menu.style.top = `${a.bottom + 4}px`;
  menu.style.left = `${Math.max(8, Math.min(window.innerWidth - width - 8, a.right - width))}px`;

  const enabled = () => buttons.filter((b) => !b.disabled);
  const move = (delta: number) => {
    const list = enabled();
    if (list.length === 0) return;
    const at = list.indexOf(document.activeElement as HTMLButtonElement);
    list[(at + delta + list.length) % list.length].focus();
  };

  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      closeMenu();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      e.stopPropagation();
      move(e.key === "ArrowDown" ? 1 : -1);
    }
  };
  const onPointer = (e: Event) => {
    if (!menu.contains(e.target as Node) && !anchor.contains(e.target as Node)) closeMenu();
  };
  const onBlur = () => void closeMenu();
  document.addEventListener("keydown", onKey, true);
  document.addEventListener("pointerdown", onPointer, true);
  window.addEventListener("blur", onBlur);
  window.addEventListener("resize", onBlur);

  close = () => {
    document.removeEventListener("keydown", onKey, true);
    document.removeEventListener("pointerdown", onPointer, true);
    window.removeEventListener("blur", onBlur);
    window.removeEventListener("resize", onBlur);
    menu.remove();
    close = null;
  };

  enabled()[0]?.focus();
}
