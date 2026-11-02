import { describe, expect, it } from "vitest";
import { THEME_KEY, attributeFor, parseChoice, readChoice, resolveTheme, saveChoice } from "./theme";

function fakeStorage(initial: Record<string, string> = {}) {
  const data = { ...initial };
  return {
    data,
    getItem: (k: string) => (k in data ? data[k] : null),
    setItem: (k: string, v: string) => void (data[k] = v),
    removeItem: (k: string) => void delete data[k],
  };
}

describe("theme choice", () => {
  it("only light and dark are real choices; anything else is auto", () => {
    expect(parseChoice("light")).toBe("light");
    expect(parseChoice("dark")).toBe("dark");
    for (const odd of [null, undefined, "", "auto", "Dark", "sepia", 1, {}]) expect(parseChoice(odd)).toBe("auto");
  });

  it("auto follows the phone; light and dark ignore it", () => {
    expect(resolveTheme("auto", true)).toBe("dark");
    expect(resolveTheme("auto", false)).toBe("light");
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
  });

  it("only an explicit choice puts data-theme on the page", () => {
    expect(attributeFor("auto")).toBeNull();
    expect(attributeFor("light")).toBe("light");
    expect(attributeFor("dark")).toBe("dark");
  });

  it("is saved on the phone; auto is saved as nothing", () => {
    const s = fakeStorage();
    saveChoice(s, "dark");
    expect(s.data[THEME_KEY]).toBe("dark");
    expect(readChoice(s)).toBe("dark");
    saveChoice(s, "auto");
    expect(THEME_KEY in s.data).toBe(false);
    expect(readChoice(s)).toBe("auto");
  });

  it("a blocked or missing storage never breaks the app", () => {
    const broken = {
      getItem: () => { throw new Error("blocked"); },
      setItem: () => { throw new Error("blocked"); },
      removeItem: () => { throw new Error("blocked"); },
    };
    expect(readChoice(broken)).toBe("auto");
    expect(() => saveChoice(broken, "dark")).not.toThrow();
    expect(readChoice(null)).toBe("auto");
    expect(() => saveChoice(null, "light")).not.toThrow();
  });
});
