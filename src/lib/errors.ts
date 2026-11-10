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
  // fingerprint and punch windows (phase 8)
  | "biometric_required"
  | "device_not_registered"
  | "device_already_registered"
  | "biometric_failed"
  | "outside_punch_window"
  | "day_off"
  // fingerprint sign-in (phase 9)
  | "too_many_attempts"
  | "password_required"
  | "biometric_off"
  | "login_disabled"
  // one phone per account (phase 16d)
  | "device_locked"
  | "device_not_bound"
  | "login_again"
  // requests
  | "invalid_dates"
  | "leave_date_not_allowed"
  | "invalid_duration"
  | "crosses_year"
  | "no_working_days"
  | "insufficient_balance"
  | "permission_limit"
  | "overlapping_request"
  | "reason_required"
  | "maternity_female_only"
  // kinds the administration added (phase 24)
  | "custom_kind_not_found"
  | "custom_kind_disabled"
  | "kind_gender_mismatch"
  | "request_not_found"
  | "already_decided"
  | "cannot_decide_own"
  | "permission_type_not_found"
  | "permission_too_long"
  | "outside_window"
  | "not_late"
  | "no_device"
  | "not_your_team"
  | "overlaps_shift"
  | "on_leave"
  | "overlapping_overtime"
  | "overtime_day_limit"
  | "overtime_month_limit"
  | "overtime_not_found"
  | "overtime_started"
  | "overtime_closed"
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
  "not_your_team", "overlaps_shift", "on_leave", "overlapping_overtime", "overtime_day_limit", "overtime_month_limit",
  "overtime_not_found", "overtime_started", "overtime_closed",
  "custom_kind_not_found", "custom_kind_disabled", "kind_gender_mismatch",
  "password_too_short", "password_too_long", "password_too_weak", "same_password", "not_required",
  "biometric_required", "device_not_registered", "device_already_registered", "biometric_failed", "outside_punch_window", "day_off",
  "too_many_attempts", "password_required", "biometric_off", "login_disabled", "leave_date_not_allowed",
  "device_locked", "device_not_bound", "login_again",
]);

export function toKnownCode(value: unknown): AppErrorCode {
  return typeof value === "string" && KNOWN.has(value as AppErrorCode) ? (value as AppErrorCode) : "unknown";
}

export const ERROR_TEXT: Record<AppErrorCode, string> = {
  network:
    "لم يصل رد من الخادم. لم نتمكن من التأكد من تسجيل العملية. اضغط «إعادة المحاولة» — لن تُسجَّل العملية مرتين.",
  not_authenticated: "انتهت الجلسة. سجّل الدخول مرة أخرى.",
  device_locked: "لا يمكنك الدخول من هاتف آخر.",
  device_not_bound: "هذا الهاتف غير مربوط بحسابك. سجّل الدخول مرة أخرى.",
  login_again: "سجّل الدخول مرة أخرى بكلمة المرور.",
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
  leave_date_not_allowed: "لا يمكن طلب إجازة تبدأ في هذا التاريخ حسب قواعد الشركة. اختر تاريخًا أبعد.",
  crosses_year: "الإجازة لا يمكن أن تمتد إلى السنة التالية. قسّمها إلى طلبين.",
  no_working_days: "لا توجد أيام عمل في هذه الفترة حسب جدول دوامك.",
  insufficient_balance: "رصيدك لا يكفي لهذه الإجازة (الطلبات المعلّقة محسوبة).",
  permission_limit: "استنفدت عدد المرات المسموح بها لهذا الإذن هذا الشهر (الطلبات المعلّقة محسوبة).",
  overlapping_request: "لديك طلب آخر في نفس الفترة.",
  reason_required: "اكتب سبب الطلب.",
  maternity_female_only: "إجازة الأمومة غير متاحة لهذا الحساب.",
  custom_kind_not_found: "هذا النوع لم يعد متاحاً.",
  custom_kind_disabled: "هذا النوع متوقف حالياً.",
  kind_gender_mismatch: "هذا النوع غير متاح لهذا الحساب.",
  request_not_found: "الطلب غير موجود أو لم يعد بانتظار قرارك.",
  already_decided: "تم البتّ في هذا الطلب من قبل.",
  cannot_decide_own: "لا يمكنك اتخاذ قرار في طلبك أنت.",
  permission_type_not_found: "اختر نوع الإذن.",
  permission_too_long: "مدة الإذن أطول من المسموح لهذا النوع.",
  outside_window: "لا يمكن طلب هذا النوع من الإذن في هذا اليوم.",
  not_late: "وقت الوصول قبل بداية دوامك، فلا يوجد تأخير.",
  no_device: "فعّل الإشعارات على هذا الجهاز أولًا.",
  not_your_team: "لا يمكنك تكليف هذا الموظف: ليس ضمن فريقك.",
  overlaps_shift: "الوقت يتداخل مع دوامه العادي. العمل الإضافي يكون قبل دوامه أو بعده أو في يوم عطلته.",
  on_leave: "الموظف في إجازة معتمدة في هذا الوقت.",
  overlapping_overtime: "لديه في هذا الوقت تكليف آخر أو إذن.",
  overtime_day_limit: "يتجاوز الحد الأقصى للعمل الإضافي في اليوم.",
  overtime_month_limit: "يتجاوز الحد الأقصى للعمل الإضافي في الشهر.",
  overtime_not_found: "التكليف غير موجود.",
  overtime_started: "بدأ وقت التكليف، فلا يمكن إلغاؤه.",
  overtime_closed: "انتهى التكليف أو أُلغي.",
  password_too_short: "كلمة المرور يجب أن تكون 8 أحرف على الأقل.",
  password_too_long: "كلمة المرور طويلة جدًا.",
  password_too_weak: "كلمة المرور يجب أن تحتوي على حرف ورقم على الأقل.",
  same_password: "كلمة المرور الجديدة يجب أن تختلف عن المؤقتة.",
  not_required: "لا يلزم تغيير كلمة المرور الآن.",
  biometric_required: "يجب تأكيد البصمة على الجهاز المسجّل لحسابك. إذا غيّرت هاتفك اطلب من الإدارة إلغاء الجهاز القديم.",
  device_not_registered: "سجّل بصمتك لهذا الجهاز أولًا.",
  device_already_registered: "يوجد جهاز مسجّل لحسابك. لتسجيل جهاز جديد اطلب من الإدارة إلغاء القديم.",
  biometric_failed: "لم تتم البصمة",
  outside_punch_window: "البصم غير متاح الآن.",
  day_off: "اليوم عطلة.",
  too_many_attempts: "محاولات كثيرة بالبصمة. انتظر 15 دقيقة، أو ادخل بكلمة المرور.",
  password_required: "هذا الحساب يدخل بكلمة المرور فقط. ادخل بكلمة المرور.",
  biometric_off: "الدخول بالبصمة غير مفعّل لشركتك. ادخل بكلمة المرور.",
  login_disabled: "أوقفتَ الدخول بالبصمة لحسابك. ادخل بكلمة المرور، ويمكنك تشغيله من «حسابي».",
  unknown: "حدث خطأ غير متوقع. حاول مرة أخرى، وإذا تكرر تواصل مع الإدارة.",
};
