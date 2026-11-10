import { useEffect, useState } from "react";
import { ERROR_TEXT } from "../lib/errors";
import {
  visibleSteps,
  KIND_LABEL,
  type Draft,
} from "../lib/requests";
import type { RequestItem, RequestType } from "../lib/types";
import { AssignOvertimeForm, MyOvertime, TeamOvertime } from "./Overtime";
import type { RequestsData } from "../hooks/useRequests";
import { AppBar, Banner, Button, Icon } from "../components";

import { Inbox } from "./requests/Inbox";
import { Balances, PermissionUsage } from "./requests/Balances";
import { MyRequests } from "./requests/MyRequests";
import { NewRequestForm } from "./requests/NewRequestForm";
type Note = { kind: "success" | "warning" | "error"; text: string };

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
  const done = (text: string, kind: "success" | "error") => { setNote({ kind, text }); reload(); };
  useEffect(() => {
    if (!compose) return;
    setNote(null);
    setAssigning(false);
    setComposing({ type: compose.type, draft: compose.draft });
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

  return (
    <>
    <AppBar  title="الطلبات" />
    <main className="container requests has-fab">
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
          <Balances overview={overview} />
          {inbox.length > 0 && (
            <Inbox items={inbox} timeZone={overview.timezone} online={online} onDone={(text, kind) => { setNote({ kind, text }); reload(); }} />
          )}
          {overtime && <MyOvertime data={overtime} online={online} onDone={done} />}
          <PermissionUsage overview={overview} />
          <MyRequests
            items={overview.requests}
            timeZone={overview.timezone}
            online={online}
            onChanged={(text, kind) => { setNote({ kind, text }); reload(); }}
          />
          {overtime && <TeamOvertime data={overtime} online={online} onDone={done} onAssign={() => { setNote(null); setAssigning(true); }} />}
        </>
      )}
    </main>
    {/* The main action of this tab floats where the punch button floats on the today tab. */}
    <button className="fab" onClick={() => { setNote(null); setComposing({ type: "leave" }); }} disabled={!overview || !online}>
      <span className="fab__icon" aria-hidden="true"><Icon name="plus" /></span>
      <span className="fab__label">طلب جديد</span>
    </button>
    </>
  );
}

function sentText(r: RequestItem): string {
  const at = visibleSteps(r.steps).find((s) => s.status === "pending");
  const who = at ? (at.kind === "hr" ? KIND_LABEL.hr : at.approver_name ?? KIND_LABEL[at.kind]) : null;
  return who ? `أُرسل الطلب، وهو الآن بانتظار: ${who}.` : "أُرسل الطلب.";
}
