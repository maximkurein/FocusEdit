import { describe, expect, it } from "vitest";
import { resolveTheme } from "../src/themes";

describe("theme: System", () => {
  it("follows the system setting", () => {
    expect(resolveTheme("System", true)).toBe("Dark");
    expect(resolveTheme("System", false)).toBe("Light");
  });
  it("leaves a chosen theme alone", () => {
    expect(resolveTheme("Sepia", true)).toBe("Sepia");
    expect(resolveTheme("Light", true)).toBe("Light");
  });
});
