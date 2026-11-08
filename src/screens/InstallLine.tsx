import { useState } from "react";
import { IOS_INSTALL_TEXT } from "../lib/install";
import { Icon } from "./ui";

/**
 * A calm line on the login screen (the only place; inside the app it never shows) that offers installing the app. Android / Chrome: «تثبيت» shows the browser's own dialog.
 * iPhone: there is no dialog, so «كيف؟» opens the instruction the app already uses. The × hides it for the session.
 */
export function InstallLine({ kind, onInstall, onClose }: { kind: "prompt" | "ios"; onInstall: () => void; onClose: () => void }) {
  const [help, setHelp] = useState(false);
  return (
    <section className="install-line" aria-label="تثبيت التطبيق">
      <Icon name="phone" className="install-icon" />
      <div className="install-body">
        <p className="install-text">ثبّت وقتي على شاشتك الرئيسية</p>
      </div>
      {kind === "prompt"
        ? <button className="btn small" type="button" onClick={onInstall}>تثبيت</button>
        : <button className="btn small" type="button" aria-expanded={help} onClick={() => setHelp((v) => !v)}>{help ? "إخفاء" : "كيف؟"}</button>}
      <button className="x" type="button" aria-label="إغلاق" onClick={onClose}><Icon name="close" /></button>
      {kind === "ios" && help && <p className="install-help">{IOS_INSTALL_TEXT}</p>}
    </section>
  );
}
