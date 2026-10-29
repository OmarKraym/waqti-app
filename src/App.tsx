import { useEffect, useState } from "react";
import type { SessionUser } from "./lib/api";
import { api, isMock } from "./lib/client";
import { ChangePassword } from "./screens/ChangePassword";
import { Home } from "./screens/Home";
import { Login } from "./screens/Login";

type Gate = { status: "booting" } | { status: "ready"; user: SessionUser | null };

export function App() {
  const [gate, setGate] = useState<Gate>({ status: "booting" });

  useEffect(() => {
    let alive = true;
    const read = () =>
      api
        .getSessionUser()
        .then((user) => alive && setGate({ status: "ready", user }))
        .catch(() => alive && setGate({ status: "ready", user: null }));
    read();
    const unsubscribe = api.onAuthChange(read);
    return () => {
      alive = false;
      unsubscribe();
    };
  }, []);

  return (
    <>
      {isMock && <div className="mock-ribbon">وضع تجريبي — بيانات وهمية</div>}
      {gate.status === "booting" ? (
        <div className="center-screen" aria-busy="true">
          <div className="spinner" />
        </div>
      ) : gate.user === null ? (
        <Login />
      ) : gate.user.mustChangePassword ? (
        <ChangePassword email={gate.user.email} />
      ) : (
        <Home />
      )}
    </>
  );
}
