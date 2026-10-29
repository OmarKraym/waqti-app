import type { WaqtiApi } from "./api";
import { createMockApi } from "./mockApi";
import { createSupabaseApi } from "./supabaseApi";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_KEY as string | undefined;
export const isMock = import.meta.env.VITE_MOCK === "1";

if (!isMock && (!url || !key)) {
  throw new Error("Missing VITE_SUPABASE_URL / VITE_SUPABASE_KEY. Copy .env.example to .env.");
}

export const api: WaqtiApi = isMock ? createMockApi() : createSupabaseApi(url!, key!);
