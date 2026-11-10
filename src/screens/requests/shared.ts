/** The icon of each request type (cards and lists). */
export const TYPE_ICON = { leave: "calendar", permission: "clock", other: "doc" } as const;

/** What a card reports back after an action: the line to show, and its colour. */
export type Done = (text: string, kind: "success" | "error") => void;
