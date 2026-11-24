import { useEffect, useState } from "react";
import { ERROR_TEXT } from "../lib/errors";
import {
  visibleSteps,
  KIND_LABEL,
  type Draft,
} from "../lib/requests";
import type { RequestItem, RequestStatus, RequestType } from "../lib/types";
import { AssignOvertimeForm, MyOvertime, TeamOvertime } from "./Overtime";
import type { RequestsData } from "../hooks/useRequests";
import { AppBar, Banner, Button, EmptyState, Icon } from "../components";

import { Inbox } from "./requests/Inbox";
import { Balances, PermissionUsage } from "./requests/Balances";
import { MyRequests } from "./requests/MyRequests";
import { NewRequestForm } from "./requests/NewRequestForm";
type Note = { kind: "success" | "warning" | "error"; text: string };
type View = "mine" | "team";
type Filter = "all" | Extract<RequestStatus, "pending" | "approved" | "rejected">;
const FILTERS: { key: Filter; label: string }[] = [
  { key: "all", label: "الكل" },
  { key: "pending", label: "قيد المراجعة" },
  { key: "approved", label: "مقبول" },
  { key: "rejected", label: "مرفوض" },
];

export function Requests({ data, online, compose }: {
  data: RequestsData;
  online: boolean;
  /** Set by the today screen's shortcuts: open the form with this type (n changes on every tap). */
  compose?: { n: number; type: RequestType; draft?: Draft } | null;
}) {
  const { overview, inbox, overtime, loading, error, savedAt, reload } = data;
  const [composing, setComposing] = useState<{ type: RequestType; draft?: Draft } | null>(compose ? { type: compose.type, draft: compose.draft } : null);
  const [assigning, setAssigning] = useState(false);
  const [note, setNote] = useState<Note | null>(null);
  const [view, setView] = useState<View>("mine");
  const [filter, setFilter] = useState<Filter>("all");
  const done = (text: string, kind: "success" | "error") => { setNote({ kind, text }); reload(); };
  useEffect(() => {
    if (!compose) return;
    setNote(null);
    setAssigning(false);
    setComposing({ type: compose.type, draft: compose.draft });
    setView("mine");
  }, [compose?.n]); // eslint-disable-line react-hooks/exhaustive-deps

  if (assigning && overtime) {
    return (
      <AssignOvertimeForm
        data={overtime}
        online={online}
        onClose={() => setAssigning(false)}
        onSent={(o) => {
          setAssigning(false);
          done(`كُلِّف ${o.employee.full_name}، ووصله إشعار.`, "success");
        }}
      />
    );
  }

  if (composing && overview) {
    return (
      <NewRequestForm
        initialType={composing.type}
        initialDraft={composing.draft}
        overview={overview}
        online={online}
        onClose={() => setComposing(null)}
        onSent={(r) => {
          setComposing(null);
          setNote({ kind: "success", text: sentText(r) });
          reload();
        }}
      />
    );
  }

  // «اعتمادات الفريق» only for someone who approves requests or assigns overtime; everyone else sees his own requests only.
  const hasTeam = inbox.length > 0 || (overtime?.team.length ?? 0) > 0;
  const shown = hasTeam ? view : "mine";
  const mine = overview ? (filter === "all" ? overview.requests : overview.requests.filter((r) => r.status === filter)) : [];
  const newButton = (
    <Button variant="primary" size="sm" className="appbar__action" onClick={() => { setNote(null); setComposing({ type: "leave" }); }} disabled={!overview || !online}>
      <Icon name="plus" />طلب جديد
    </Button>
  );

  return (
    <>
    <AppBar title="الطلبات" sub="الإجازات والأذونات والموافقات" action={newButton} />
    <main className="container requests">
      {!online && <Banner kind="warning">الطلبات تحتاج اتصالًا بالإنترنت.</Banner>}
      {note && <Banner kind={note.kind} onClose={() => setNote(null)}>{note.text}</Banner>}

      {!overview ? (
        loading ? (
          <div className="center-block" aria-busy="true"><div className="spinner" /></div>
        ) : (
          <div className="card pad">
            <Icon name="alert" className="pad__icon" />
            <p className="u-muted">{error?.code === "network" ? "تحقق من اتصالك بالإنترنت." : ERROR_TEXT[error?.code ?? "unknown"]}</p>
            <Button variant="primary" onClick={reload}>إعادة المحاولة</Button>
          </div>
        )
      ) : (
        <>
          {savedAt !== null && (
            <p className="summary__stale">آخر تحديث {new Date(savedAt).toLocaleDateString("en-GB")} {new Date(savedAt).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })} — {online ? "تعذّر التحديث الآن." : "لا يوجد اتصال."}</p>
          )}
          {hasTeam && (
            <div className="seg seg--2" role="tablist" aria-label="عرض الطلبات">
              <button type="button" role="tab" aria-selected={shown === "mine"} className={`seg__btn${shown === "mine" ? " is-active" : ""}`} onClick={() => setView("mine")}>
                طلباتي
              </button>
              <button type="button" role="tab" aria-selected={shown === "team"} className={`seg__btn${shown === "team" ? " is-active" : ""}`} onClick={() => setView("team")}>
                اعتمادات الفريق
                {inbox.length > 0 && <span className="count" aria-label={`${inbox.length} بانتظار موافقتك`}>{inbox.length}</span>}
              </button>
            </div>
          )}

          {shown === "mine" ? (
            <>
              <Balances overview={overview} />
              {overtime && <MyOvertime data={overtime} online={online} onDone={done} />}
              <PermissionUsage overview={overview} />
              {overview.requests.length > 0 && (
                <div className="filters" role="tablist" aria-label="تصفية الطلبات">
                  {FILTERS.map((f) => (
                    <button key={f.key} type="button" role="tab" aria-selected={filter === f.key}
                      className={`filter${filter === f.key ? " is-active" : ""}`} onClick={() => setFilter(f.key)}>
                      {f.label}
                    </button>
                  ))}
                </div>
              )}
              <MyRequests
                items={mine}
                filtered={filter !== "all"}
                timeZone={overview.timezone}
                online={online}
                onChanged={(text, kind) => { setNote({ kind, text }); reload(); }}
              />
            </>
          ) : (
            <>
              {inbox.length > 0 ? (
                <Inbox items={inbox} timeZone={overview.timezone} online={online} onDone={(text, kind) => { setNote({ kind, text }); reload(); }} />
              ) : (
                <EmptyState icon="inbox">لا توجد طلبات بانتظار موافقتك حاليًا.</EmptyState>
              )}
              {overtime && <TeamOvertime data={overtime} online={online} onDone={done} onAssign={() => { setNote(null); setAssigning(true); }} />}
            </>
          )}
        </>
      )}
    </main>
    </>
  );
}

function sentText(r: RequestItem): string {
  const at = visibleSteps(r.steps).find((s) => s.status === "pending");
  const who = at ? (at.kind === "hr" ? KIND_LABEL.hr : at.approver_name ?? KIND_LABEL[at.kind]) : null;
  return who ? `أُرسل الطلب، وهو الآن بانتظار: ${who}.` : "أُرسل الطلب.";
}
