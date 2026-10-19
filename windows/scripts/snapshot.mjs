// Screenshot the built UI in Google Chrome (no Tauri, no browser download):
//   npm run build && npm run snapshot -- [--theme Dark] [out.png]
// Loads examples/welcome.md, types a demo line (list continuation + grey
// completion) and saves a PNG. Uses the installed Chrome via playwright-core.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { preview } from "vite";

const args = process.argv.slice(2);
const themeIndex = args.indexOf("--theme");
const theme = themeIndex >= 0 ? args[themeIndex + 1] : "Light";
const out = args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--theme") ?? "snapshot.png";

const welcome = await readFile(fileURLToPath(new URL("../../examples/welcome.md", import.meta.url)), "utf8");
const server = await preview({ preview: { port: 1421, strictPort: true } });
const browser = await chromium.launch({ channel: "chrome", headless: true });

try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 760 }, deviceScaleFactor: 2 });
  await page.addInitScript((t) => {
    localStorage.setItem("focusedit.settings.v1", JSON.stringify({ theme: t }));
  }, theme);
  await page.goto("http://localhost:1421/");
  await page.evaluate((text) => window.focusEdit.load(text, "welcome.md"), welcome);
  await page.keyboard.press(process.platform === "darwin" ? "Meta+End" : "Control+End");
  for (const key of ["Enter", ..."- First idea", "Enter", ..."Mark"]) {
    await page.keyboard.press(key === " " ? "Space" : key);
  }
  await page.waitForTimeout(400); // focus fade transition
  await page.screenshot({ path: out });
  console.log(`snapshot: wrote ${out} (${theme})`);
} finally {
  await browser.close();
  server.httpServer.close();
}
