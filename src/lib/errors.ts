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
  | "clock_changed"
  | "time_unverified"
  | "time_order"
  | "offline_too_old"
  // requests
  | "invalid_dates"
  | "invalid_duration"
  | "crosses_year"
  | "no_working_days"
  | "insufficient_balance"
  | "permission_limit"
  | "overlapping_request"
  | "reason_required"
  | "maternity_female_only"
  | "request_not_found"
  | "already_decided"
  | "cannot_decide_own"
  | "permission_type_not_found"
  | "permission_too_long"
  | "outside_window"
  | "not_late"
  | "no_device"
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
  "geofence_not_configured", "invalid_input", "clock_changed", "time_unverified", "time_order", "offline_too_old",
  "invalid_dates", "invalid_duration", "crosses_year", "no_working_days", "insufficient_balance", "permission_limit",
  "overlapping_request", "reason_required", "maternity_female_only", "request_not_found", "already_decided",
  "cannot_decide_own", "permission_type_not_found", "permission_too_long", "outside_window", "not_late", "no_device",
  "password_too_short", "password_too_long", "password_too_weak", "same_password", "not_required",
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
  clock_changed: "تغيّرت ساعة الهاتف بعد آخر اتصال بالإنترنت، فلم يُقبل هذا التسجيل. اجعل الوقت على «تلقائي» وتواصل مع الإدارة.",
  time_unverified: "تعذّر التحقق من وقت هذا التسجيل، فلم يُقبل. تواصل مع الإدارة.",
  time_order: "وقت هذا التسجيل قبل آخر حركة مسجّلة لك، فلم يُقبل. تواصل مع الإدارة.",
  offline_too_old: "وصل هذا التسجيل بعد أكثر من 72 ساعة، فلم يُقبل. تواصل مع الإدارة.",
  invalid_dates: "التاريخ غير صالح. تأكد أن النهاية بعد البداية، وأن التاريخ ليس بعيدًا جدًا في الماضي أو المستقبل.",
  invalid_duration: "مدة الإذن يجب أن تكون بين ربع ساعة و8 ساعات.",
  crosses_year: "الإجازة لا يمكن أن تمتد إلى السنة التالية. قسّمها إلى طلبين.",
  no_working_days: "لا توجد أيام عمل في هذه الفترة حسب جدول دوامك.",
  insufficient_balance: "رصيدك لا يكفي لهذه الإجازة (الطلبات المعلّقة محسوبة).",
  permission_limit: "استنفدت عدد المرات المسموح بها لهذا الإذن هذا الشهر (الطلبات المعلّقة محسوبة).",
  overlapping_request: "لديك طلب آخر في نفس الفترة.",
  reason_required: "اكتب سبب الطلب.",
  maternity_female_only: "إجازة الأمومة غير متاحة لهذا الحساب.",
  request_not_found: "الطلب غير موجود أو لم يعد بانتظار قرارك.",
  already_decided: "تم البتّ في هذا الطلب من قبل.",
  cannot_decide_own: "لا يمكنك اتخاذ قرار في طلبك أنت.",
  permission_type_not_found: "اختر نوع الإذن.",
  permission_too_long: "مدة الإذن أطول من المسموح لهذا النوع.",
  outside_window: "لا يمكن طلب هذا النوع من الإذن في هذا اليوم.",
  not_late: "وقت الوصول قبل بداية دوامك، فلا يوجد تأخير.",
  no_device: "فعّل الإشعارات على هذا الجهاز أولًا.",
  password_too_short: "كلمة المرور يجب أن تكون 8 أحرف على الأقل.",
  password_too_long: "كلمة المرور طويلة جدًا.",
  password_too_weak: "كلمة المرور يجب أن تحتوي على حرف ورقم على الأقل.",
  same_password: "كلمة المرور الجديدة يجب أن تختلف عن المؤقتة.",
  not_required: "لا يلزم تغيير كلمة المرور الآن.",
  unknown: "حدث خطأ غير متوقع. حاول مرة أخرى، وإذا تكرر تواصل مع الإدارة.",
};
