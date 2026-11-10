import { useEffect, useMemo, useRef, useState } from "react";
import { newRequestId } from "../lib/attendance";
import { api } from "../lib/client";
import { AppError, type AppErrorCode } from "../lib/errors";
import {
  customKindsOf,
  draftToRequest,
  clampLeaveDates,
  emptyDraft,
  leaveEarliest,
  permissionTimesFilled,
  requestSignature,
  type Draft,
} from "../lib/requests";
import type { RequestItem, RequestPreview, RequestType, RequestsOverview } from "../lib/types";
import { overBalanceLine } from "../lib/leaveBalance";

const PREVIEW_DELAY_MS = 400;

/**
 * The new-request form without its markup: the draft, the server preview (debounced, by content signature), what
 * blocks sending and why, the over-balance line, and a send that never creates the same request twice.
 */
export function useNewRequest({ initialType, initialDraft, overview, online, onSent }: {
  initialType: RequestType; initialDraft?: Draft; overview: RequestsOverview; online: boolean; onSent: (r: RequestItem) => void;
}) {
  const tz = overview.timezone;
  const ptypes = overview.permission_types;
  const earliest = leaveEarliest(overview);
  const [draft, setDraft] = useState<Draft>(() => clampLeaveDates(initialDraft ?? { ...emptyDraft(overview.today, ptypes[0]), type: initialType }, earliest));
  const ptype = ptypes.find((p) => p.id === draft.permission_type_id) ?? null;
  const [preview, setPreview] = useState<{ sig: string; result: RequestPreview } | null>(null);
  const [previewError, setPreviewError] = useState<{ sig: string; code: AppErrorCode } | null>(null);
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<AppErrorCode | null>(null);
  // One key per request content: a retry of the same content never creates a second request.
  const key = useRef<{ sig: string; key: string } | null>(null);

  const leaveTypes = useMemo(() => overview.balances.map((b) => b.leave_type), [overview.balances]);
  // kinds the administration added (none from an older database: the form is then exactly the built-in one)
  const leaveKinds = useMemo(() => customKindsOf(overview, "leave"), [overview]);
  const otherKinds = useMemo(() => customKindsOf(overview, "other"), [overview]);
  const kind = [...leaveKinds, ...otherKinds].find((k) => k.id === draft.custom_kind_id && k.family === draft.type) ?? null;
  const built = draftToRequest(draft, tz, overview.custom_kinds ?? []);
  const sig = built.ok ? requestSignature(built.request) : null;

  useEffect(() => {
    if (!built.ok || !online) return;
    const request = built.request;
    const s = requestSignature(request);
    let alive = true;
    const t = setTimeout(async () => {
      try {
        const result = await api.previewRequest(request);
        if (alive) { setPreview({ sig: s, result }); setPreviewError(null); }
      } catch (e) {
        if (alive) setPreviewError({ sig: s, code: e instanceof AppError ? e.code : "unknown" });
      }
    }, PREVIEW_DELAY_MS);
    return () => { alive = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the signature is the content
  }, [sig, online]);

  const set = (patch: Partial<Draft>) => {
    setSendError(null);
    setDraft((d) => {
      const next = { ...d, ...patch };
      // A kind belongs to one form: leaving the form forgets it (and a leave goes back to the first built-in type).
      if (patch.type && patch.type !== d.type && patch.custom_kind_id === undefined) {
        next.custom_kind_id = "";
        if (next.leave_type === "custom") next.leave_type = "annual";
      }
      if (patch.start_date && next.end_date < patch.start_date) next.end_date = patch.start_date;
      if (next.type === "other") {
        const mode = otherKinds.find((k) => k.id === next.custom_kind_id)?.date_mode ?? null;
        // "Other" request without a date (plain, or a kind without one): the employee is not asked; it is today.
        if (mode === null || mode === "none") { next.start_date = overview.today; next.end_date = overview.today; }
        else if (mode === "single") next.end_date = next.start_date;
      }
      // Switching to a leave starts from an allowed day; typing a date is never moved under the finger (the message tells why).
      return patch.type ? clampLeaveDates(next, earliest) : next;
    });
  };

  const current = preview && preview.sig === sig ? preview.result : null;
  const problem: AppErrorCode | null = !built.ok
    ? (draft.type === "permission" && !permissionTimesFilled(draft)) || built.error === "reason_required"
      ? null // not filled in yet: no red text
      : built.error
    : draft.type === "leave" && draft.start_date < earliest ? "leave_date_not_allowed"
    : previewError && previewError.sig === sig ? previewError.code : null;
  // More than the balance (phase 18a): allowed with a reason; the administration decides. Kept while the reason is
  // typed (the preview runs again then), so the line and the "required" label do not flicker.
  const datesSig = built.ok && built.request.type === "leave" ? requestSignature({ ...built.request, reason: null }) : null;
  const lastOver = useRef<{ sig: string; line: string | null } | null>(null);
  if (current && datesSig && draft.type === "leave") lastOver.current = { sig: datesSig, line: overBalanceLine(current) };
  const over = datesSig && lastOver.current?.sig === datesSig ? lastOver.current.line : null;
  const canSend = built.ok && current !== null && problem === null && !sending && online && (!over || draft.reason.trim() !== "");

  async function send() {
    if (!built.ok || !canSend) return;
    if (!key.current || key.current.sig !== sig) key.current = { sig: sig!, key: newRequestId() };
    setSending(true);
    setSendError(null);
    try {
      onSent(await api.submitRequest(key.current.key, built.request));
    } catch (e) {
      setSendError(e instanceof AppError ? e.code : "unknown");
    } finally {
      setSending(false);
    }
  }

  return { tz, ptypes, earliest, draft, ptype, leaveTypes, leaveKinds, otherKinds, kind, built, current, problem, over, canSend, sending, sendError, set, send };
}
