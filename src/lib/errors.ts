// One error type for everything the screens show.
// "network" is special: we do NOT know if the server processed the request.

export type AppErrorCode =
  // connection
  | "network"
  // auth / account
  | "not_authenticated"
  | "invalid_credentials"
  | "employee_inactive"
  | "must_change_password"
  | "forbidden"
  // attendance
  | "state_changed"
  | "outside_geofence"
  | "location_required"
  | "location_inaccurate"
  | "rate_limited"
  | "geofence_not_configured"
  | "invalid_input"
  // change password
  | "password_too_short"
  | "password_too_long"
  | "password_too_weak"
  | "same_password"
  | "not_required"
  // anything else
  | "unknown";

export class AppError extends Error {
  constructor(public code: AppErrorCode, detail?: string) {
    super(detail ?? code);
    this.name = "AppError";
  }
}

const KNOWN = new Set<AppErrorCode>([
  "not_authenticated", "invalid_credentials", "employee_inactive", "must_change_password", "forbidden",
  "state_changed", "outside_geofence", "location_required", "location_inaccurate", "rate_limited",
  "geofence_not_configured", "invalid_input", "password_too_short", "password_too_long", "password_too_weak", "same_password", "not_required",
]);

export function toKnownCode(value: unknown): AppErrorCode {
  return typeof value === "string" && KNOWN.has(value as AppErrorCode) ? (value as AppErrorCode) : "unknown";
}

export const ERROR_TEXT: Record<AppErrorCode, string> = {
  network:
    "لم يصل رد من الخادم. لم نتمكن من التأكد من تسجيل العملية. اضغط «إعادة المحاولة» — لن تُسجَّل العملية مرتين.",
  not_authenticated: "انتهت الجلسة. سجّل الدخول مرة أخرى.",
  invalid_credentials: "البريد الإلكتروني أو كلمة المرور غير صحيحة.",
  employee_inactive: "حسابك غير مفعّل. تواصل مع إدارة شركتك.",
  must_change_password: "يجب تغيير كلمة المرور المؤقتة أولًا.",
  forbidden: "ليست لديك صلاحية لهذه العملية.",
  state_changed: "تغيّرت حالة حضورك (ربما من جهاز آخر). تم تحديث الشاشة، تأكد ثم حاول مرة أخرى.",
  outside_geofence: "أنت خارج نطاق مكان العمل المعتمد. لم يتم التسجيل.",
  location_required: "لم نتمكن من تحديد موقعك، وسياسة شركتك تتطلب الموقع. فعّل خدمة الموقع ثم حاول مرة أخرى.",
  location_inaccurate: "دقة الموقع ضعيفة جدًا للتحقق. انتقل إلى مكان مفتوح وحاول مرة أخرى.",
  rate_limited: "محاولات كثيرة خلال وقت قصير. انتظر قليلًا ثم حاول مرة أخرى.",
  geofence_not_configured: "لم يُحدَّد نطاق مكان العمل لحسابك بعد. تواصل مع إدارة شركتك.",
  invalid_input: "طلب غير صالح. حدّث الصفحة وحاول مرة أخرى.",
  password_too_short: "كلمة المرور يجب أن تكون 8 أحرف على الأقل.",
  password_too_long: "كلمة المرور طويلة جدًا.",
  password_too_weak: "كلمة المرور يجب أن تحتوي على حرف ورقم على الأقل.",
  same_password: "كلمة المرور الجديدة يجب أن تختلف عن المؤقتة.",
  not_required: "لا يلزم تغيير كلمة المرور الآن.",
  unknown: "حدث خطأ غير متوقع. حاول مرة أخرى، وإذا تكرر تواصل مع الإدارة.",
};
