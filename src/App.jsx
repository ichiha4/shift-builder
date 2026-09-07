import { useState, useEffect, useMemo, useRef } from "react";
import { ChevronLeft, ChevronRight, Trash2, Plus, Clock3, Wallet, Receipt, Home, TrendingUp, TrendingDown, X, Info, ChevronDown, Download, Upload, ArrowRight, Moon, Sun, Settings, Bell, CalendarPlus } from "lucide-react";

const CATEGORIES = ["食費", "交通費", "日用品", "娯楽", "家賃・光熱", "通信費", "その他"];
const CAT_COLORS = {
  "食費": "#F59E0B", "交通費": "#3B82F6", "日用品": "#10B981", "娯楽": "#A855F7",
  "家賃・光熱": "#F43F5E", "通信費": "#06B6D4", "その他": "#6B7280",
};
const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];
const EMPLOYMENT_TYPES = ["アルバイト", "パート", "契約社員", "正社員", "その他"];
const DIFF_REASONS = ["控除額の違い", "交通費の違い", "手当の違い", "勤務時間の違い", "割増賃金の違い"];

const LATE_NIGHT_START = 22 * 60;
const LATE_NIGHT_END = 5 * 60;
const DAILY_OT_THRESHOLD = 8 * 60;
const WEEKLY_OT_THRESHOLD = 40 * 60;
const DEFAULT_RATES = { lateNight: 0.25, overtime: 0.25, holiday: 0.35 };

function uid() {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}
function toMin(hhmm) {
  const [h, m] = hhmm.split(":").map(Number);
  return h * 60 + m;
}
function calcMinutes(start, end) {
  let s = toMin(start), e = toMin(end);
  if (e <= s) e += 24 * 60;
  return Math.max(0, e - s);
}
function isLateNightMinute(clockMin) {
  const t = ((clockMin % 1440) + 1440) % 1440;
  return t >= LATE_NIGHT_START || t < LATE_NIGHT_END;
}

function migrateShift(s) {
  const segments = s.segments || [{ start: s.start, end: s.end, wage: s.wage }];
  return {
    ...s,
    segments,
    breakMin: s.breakMin || 0,
    breakStart: s.breakStart || "",
    breakEnd: s.breakEnd || "",
    transport: s.transport || 0,
    otherAllowance: s.otherAllowance || 0,
    isStatutoryHoliday: !!s.isStatutoryHoliday,
    scheduledMin: s.scheduledMin != null ? s.scheduledMin : DAILY_OT_THRESHOLD,
    lateNightRate: s.lateNightRate != null ? s.lateNightRate : DEFAULT_RATES.lateNight,
    overtimeRate: s.overtimeRate != null ? s.overtimeRate : DEFAULT_RATES.overtime,
    holidayRate: s.holidayRate != null ? s.holidayRate : DEFAULT_RATES.holiday,
  };
}

function migrateEmployer(e) {
  return {
    id: e.id,
    name: e.name,
    scheduledHours: e.scheduledHours || 8,
    defaultWage: e.defaultWage || "",
    defaultTransport: e.defaultTransport || 0,
    // closingDay/paydayDay: 1-31, or 0 meaning "末日" (last day of the month).
    // paydayMonthOffset: 0 = same month as the closing date, 1 = the following month.
    closingDay: e.closingDay != null ? e.closingDay : 0,
    paydayMonthOffset: e.paydayMonthOffset != null ? e.paydayMonthOffset : 1,
    paydayDay: e.paydayDay != null ? e.paydayDay : 25,
    lateNightRate: e.lateNightRate != null ? e.lateNightRate : DEFAULT_RATES.lateNight,
    overtimeRate: e.overtimeRate != null ? e.overtimeRate : DEFAULT_RATES.overtime,
    holidayRate: e.holidayRate != null ? e.holidayRate : DEFAULT_RATES.holiday,
    otherAllowance: e.otherAllowance || 0,
    employmentType: e.employmentType || "アルバイト",
  };
}

// データの保存先。Claudeのアーティファクト環境では window.storage が用意されているが、
// 通常のブラウザには存在しないため、その場合は localStorage で代用する。
// インターフェイス(get は {value} か null を返す / set は文字列を保存する)は揃えてある。
const storage = (typeof window !== "undefined" && window.storage) ? window.storage : {
  async get(key) {
    const v = localStorage.getItem(key);
    return v === null ? null : { key, value: v };
  },
  async set(key, value) {
    localStorage.setItem(key, value);
    return { key, value };
  },
  async delete(key) {
    localStorage.removeItem(key);
    return { key, deleted: true };
  },
};

// ローカルタイムの Date を YYYY-MM-DD にする。
// toISOString() はUTCに変換してしまうため、日本時間だと日付が1日前にずれる。
// 日付文字列を作るときは必ずこちらを使う。
function ymd(dateObj) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${dateObj.getFullYear()}-${pad(dateObj.getMonth() + 1)}-${pad(dateObj.getDate())}`;
}
function todayYMD() {
  return ymd(new Date());
}

// --- Pay-period / payday calculation -------------------------------------------------
// A shift's calendar date and the month it's actually PAID in are not the same thing.
// closingDay defines the cutoff (e.g. 15th → periods run 16th–15th); paydayMonthOffset/Day
// define when that period is paid out (e.g. offset=1, day=25 → the 25th of the next month).
function lastDayOfMonth(y, m1to12) { return new Date(y, m1to12, 0).getDate(); }

function resolveDay(y, m1to12, day) {
  // day: 1-31, or 0 for "末日" (end of month) — clamped to the actual number of days.
  const last = lastDayOfMonth(y, m1to12);
  return day === 0 ? last : Math.min(day, last);
}

// Given a worked date and an employer's closing day, returns the pay period it falls into.
function computePayPeriod(dateStr, closingDay) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const thisMonthClose = resolveDay(y, m, closingDay);
  let endY = y, endM = m;
  if (d > thisMonthClose) { endM += 1; if (endM > 12) { endM = 1; endY += 1; } }
  const endDay = resolveDay(endY, endM, closingDay);
  const periodEnd = `${endY}-${String(endM).padStart(2, "0")}-${String(endDay).padStart(2, "0")}`;
  let startY = endY, startM = endM - 1;
  if (startM < 1) { startM = 12; startY -= 1; }
  const startCloseDay = resolveDay(startY, startM, closingDay);
  const startDate = new Date(startY, startM - 1, startCloseDay);
  startDate.setDate(startDate.getDate() + 1);
  const periodStart = ymd(startDate);
  return { periodStart, periodEnd, periodKey: periodEnd };
}

// Given a pay period's end date, returns the date it's actually paid on.
function computePaymentDate(periodEnd, paydayMonthOffset, paydayDay) {
  const [y, m] = periodEnd.split("-").map(Number);
  let payY = y, payM = m + paydayMonthOffset;
  while (payM > 12) { payM -= 12; payY += 1; }
  const day = resolveDay(payY, payM, paydayDay);
  return `${payY}-${String(payM).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function formatPeriodDate(dateStr) {
  const [, m, d] = dateStr.split("-").map(Number);
  return `${m}/${d}`;
}
function formatFullDate(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  return `${y}年${m}月${d}日`;
}

function migrateActualPay(v) {
  if (v == null) return null;
  if (typeof v === "number") return { amounts: { gross: v }, hours: {}, reasons: [], note: "" };
  if (v.amount != null && v.amounts == null) return { amounts: { gross: v.amount }, hours: {}, reasons: v.reasons || [], note: v.note || "" };
  return { amounts: v.amounts || {}, hours: v.hours || {}, reasons: v.reasons || [], note: v.note || "" };
}

const DEDUCTION_CATEGORIES = ["健康保険料", "厚生年金保険料", "雇用保険料", "所得税", "住民税", "その他控除"];

// Older records only had a free-text `label`. Map it onto a fixed category so every
// deduction can be reasoned about independently (and, eventually, checked against a real
// payslip line by line). Anything that doesn't match a known category becomes "その他控除"
// with the original text preserved as a note, so nothing is silently lost.
function migrateDeduction(d) {
  if (d.category) return { ...d, note: d.note || "" };
  const label = d.label || "";
  const category = DEDUCTION_CATEGORIES.includes(label) ? label : "その他控除";
  const note = category === "その他控除" && label ? label : (d.note || "");
  return { id: d.id, month: d.month, category, amount: d.amount, note };
}

function expandSegments(segments, breakStart, breakMin) {
  const minutes = [];
  segments.forEach((seg) => {
    const s = toMin(seg.start);
    let e = toMin(seg.end);
    if (e <= s) e += 1440;
    const wage = Number(seg.wage || 0);
    for (let t = s; t < e; t++) minutes.push({ clockMin: t, wage });
  });
  if (breakStart && breakMin > 0) {
    const bs = toMin(breakStart);
    const be = bs + Number(breakMin);
    return minutes.filter((m) => !(m.clockMin >= bs && m.clockMin < be));
  }
  return minutes;
}

function formatClock(clockMin) {
  const t = ((clockMin % 1440) + 1440) % 1440;
  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
}

// Merges a set of individual worked minutes into contiguous "HH:MM–HH:MM" range strings.
// e.g. minutes [1320,1321,...,1379] (22:00–23:00) -> ["22:00–23:00"]
function minutesToRanges(minuteList) {
  if (minuteList.length === 0) return [];
  const sorted = [...new Set(minuteList)].sort((a, b) => a - b);
  const ranges = [];
  let start = sorted[0], prev = sorted[0];
  for (let i = 1; i <= sorted.length; i++) {
    const cur = sorted[i];
    if (cur === prev + 1) { prev = cur; continue; }
    ranges.push(`${formatClock(start)}–${formatClock(prev + 1)}`);
    start = cur; prev = cur;
  }
  return ranges;
}

// Same as minutesToRanges, but also breaks a range wherever the applicable wage changes,
// and returns a human-readable formula for each segment: "22:00–23:00 (1.0h) × ¥1200 × 25% = ¥300"
function minutesToFormulaLines(minuteWagePairs, rate) {
  if (minuteWagePairs.length === 0) return [];
  const sorted = [...minuteWagePairs].sort((a, b) => a.clockMin - b.clockMin);
  const lines = [];
  let runStart = sorted[0].clockMin, runPrev = sorted[0].clockMin, runWage = sorted[0].wage;
  function flush(endExclusive) {
    const durMin = endExclusive - runStart;
    const amount = (durMin / 60) * runWage * rate;
    lines.push({
      range: `${formatClock(runStart)}–${formatClock(endExclusive)}`,
      hours: durMin / 60,
      wage: runWage,
      rate,
      amount,
    });
  }
  for (let i = 1; i <= sorted.length; i++) {
    const cur = sorted[i];
    if (cur && cur.clockMin === runPrev + 1 && cur.wage === runWage) { runPrev = cur.clockMin; continue; }
    flush(runPrev + 1);
    if (cur) { runStart = cur.clockMin; runPrev = cur.clockMin; runWage = cur.wage; }
  }
  return lines;
}

// Single-shift, context-free estimate. Used ONLY for the live preview in the add-shift form,
// where the shift hasn't been saved yet and we can't know how it interacts with other shifts
// on the same day/week. The real, committed calculation is calculateShiftPay() below, which
// aggregates per employer across day and week before classifying overtime.
function estimateShiftPay(shift) {
  const segments = shift.segments || [];
  const breakMin = Number(shift.breakMin || 0);
  const breakStart = shift.breakStart || "";
  const transport = Number(shift.transport || 0);
  const otherAllowance = Number(shift.otherAllowance || 0);
  const isStatutoryHoliday = !!shift.isStatutoryHoliday;
  const scheduledMin = shift.scheduledMin != null ? shift.scheduledMin : DAILY_OT_THRESHOLD;
  const lateNightRate = shift.lateNightRate != null ? shift.lateNightRate : DEFAULT_RATES.lateNight;
  const overtimeRate = shift.overtimeRate != null ? shift.overtimeRate : DEFAULT_RATES.overtime;
  const holidayRate = shift.holidayRate != null ? shift.holidayRate : DEFAULT_RATES.holiday;
  const preciseBreak = !!breakStart && breakMin > 0;

  const minutes = expandSegments(segments, breakStart, breakMin);
  const rawTotalMin = minutes.length;
  const netMin = preciseBreak ? rawTotalMin : Math.max(0, rawTotalMin - breakMin);
  const overtimeMinCount = isStatutoryHoliday ? 0 : Math.max(0, netMin - scheduledMin);

  let base = 0, lateNightExtra = 0, overtimeExtra = 0, holidayExtra = 0;
  let lateNightMin = 0, overtimeMin = 0, holidayMin = 0;
  minutes.forEach((min, idx) => {
    const perMinWage = min.wage / 60;
    base += perMinWage;
    if (isLateNightMinute(min.clockMin)) { lateNightExtra += perMinWage * lateNightRate; lateNightMin++; }
    if (isStatutoryHoliday) { holidayExtra += perMinWage * holidayRate; holidayMin++; }
    else if (idx >= minutes.length - overtimeMinCount) { overtimeExtra += perMinWage * overtimeRate; overtimeMin++; }
  });

  const grossPay = base + lateNightExtra + overtimeExtra + holidayExtra;
  let netPayBeforeExtras = grossPay;
  if (!preciseBreak && breakMin > 0 && rawTotalMin > 0) {
    const perMin = grossPay / rawTotalMin;
    netPayBeforeExtras = Math.max(0, grossPay - breakMin * perMin);
  }
  const netPay = netPayBeforeExtras + transport + otherAllowance;

  return {
    totalMin: rawTotalMin, netMin, base, lateNightExtra, overtimeExtra, holidayExtra,
    lateNightMin, overtimeMin, holidayMin, netPay,
    breakdown: { base, lateNightExtra, overtimeExtra, holidayExtra },
  };
}

// Expands one shift into its worked-minute array, plus a scalar netMin used for day/week
// totals. When the break's start time is known, minutes are removed exactly; otherwise the
// raw array is kept (so late-night/tail marking still has clock positions to work with) and
// netMin is reduced by breakMin as a scalar — the same averaging approximation used before,
// now also feeding the cross-shift day/week aggregation below.
function expandShiftMinutes(shift) {
  const segments = shift.segments || [];
  const breakMin = Number(shift.breakMin || 0);
  const breakStart = shift.breakStart || "";
  const raw = expandSegments(segments, "", 0);
  const preciseBreak = !!breakStart && breakMin > 0;
  if (preciseBreak) {
    const bs = toMin(breakStart);
    const be = bs + breakMin;
    const filtered = raw.filter((m) => !(m.clockMin >= bs && m.clockMin < be));
    return { minutes: filtered, netMin: filtered.length, rawLen: raw.length, preciseBreak: true, breakMin };
  }
  const netMin = Math.max(0, raw.length - breakMin);
  return { minutes: raw, netMin, rawLen: raw.length, preciseBreak: false, breakMin };
}

// Aggregates one employer's shifts by day, then by week, to classify every worked minute as
// normal / scheduled_ot (所定内残業, no premium) / daily_legal_ot (>8h/day) / weekly_legal_ot
// (>40h/week, only counted against minutes not already daily-OT to avoid double counting).
// Statutory-holiday shifts are excluded — their premium is computed separately.
function classifyEmployerOvertime(employerShifts) {
  const workable = employerShifts.filter((s) => !s.isStatutoryHoliday);
  const shiftData = {};
  workable.forEach((s) => {
    const exp = expandShiftMinutes(s);
    shiftData[s.id] = { exp, minutes: exp.minutes.map((m) => ({ ...m, bucket: "normal" })) };
  });

  const byDate = {};
  workable.forEach((s) => { (byDate[s.date] = byDate[s.date] || []).push(s); });

  const dayInfo = {};
  Object.keys(byDate).forEach((date) => {
    // Sort chronologically so the day's 所定労働時間 is read from whichever shift actually
    // starts first that day — not just whichever happened to be added first.
    const shiftsOnDay = [...byDate[date]].sort((a, b) => toMin(a.segments[0].start) - toMin(b.segments[0].start));
    const scheduledMin = shiftsOnDay[0].scheduledMin != null ? shiftsOnDay[0].scheduledMin : DAILY_OT_THRESHOLD;
    let totalMin = 0;
    shiftsOnDay.forEach((s) => { totalMin += shiftData[s.id].exp.netMin; });
    const legalOTMin = Math.max(0, totalMin - DAILY_OT_THRESHOLD);
    const scheduledOTMin = Math.max(0, Math.min(totalMin, DAILY_OT_THRESHOLD) - scheduledMin);
    dayInfo[date] = { totalMin, legalOTMin, scheduledOTMin, shiftIds: shiftsOnDay.map((s) => s.id) };

    const combined = [];
    shiftsOnDay.forEach((s) => { shiftData[s.id].minutes.forEach((m, idx) => combined.push({ shiftId: s.id, idx, clockMin: m.clockMin })); });
    combined.sort((a, b) => a.clockMin - b.clockMin);
    let remainingLegal = legalOTMin, remainingScheduled = scheduledOTMin;
    for (let i = combined.length - 1; i >= 0 && (remainingLegal > 0 || remainingScheduled > 0); i--) {
      const c = combined[i];
      if (remainingLegal > 0) { shiftData[c.shiftId].minutes[c.idx].bucket = "daily_legal_ot"; remainingLegal--; }
      else if (remainingScheduled > 0) { shiftData[c.shiftId].minutes[c.idx].bucket = "scheduled_ot"; remainingScheduled--; }
    }
  });

  const byWeek = {};
  Object.keys(dayInfo).forEach((date) => { (byWeek[mondayOfWeek(date)] = byWeek[mondayOfWeek(date)] || []).push(date); });
  Object.keys(byWeek).forEach((wk) => {
    const dates = byWeek[wk].sort();
    const weeklyNonDailyOTMin = dates.reduce((sum, d) => sum + (dayInfo[d].totalMin - dayInfo[d].legalOTMin), 0);
    // The 40h line is judged against minutes not already daily-OT, so a hour already paid at
    // the daily-overtime rate is never counted twice.
    const excess = Math.max(0, weeklyNonDailyOTMin - WEEKLY_OT_THRESHOLD);
    let weeklyLegalOTMin = Math.min(excess, weeklyNonDailyOTMin);
    if (weeklyLegalOTMin <= 0) return;

    const pool = [];
    dates.forEach((date) => {
      dayInfo[date].shiftIds.forEach((shiftId) => {
        shiftData[shiftId].minutes.forEach((m, idx) => {
          if (m.bucket === "normal" || m.bucket === "scheduled_ot") pool.push({ shiftId, idx, date, clockMin: m.clockMin });
        });
      });
    });
    pool.sort((a, b) => (a.date === b.date ? a.clockMin - b.clockMin : a.date.localeCompare(b.date)));
    for (let i = pool.length - 1; i >= 0 && weeklyLegalOTMin > 0; i--) {
      const p = pool[i];
      shiftData[p.shiftId].minutes[p.idx].bucket = "weekly_legal_ot";
      weeklyLegalOTMin--;
    }
  });

  const result = {};
  Object.keys(shiftData).forEach((id) => { result[id] = shiftData[id]; });
  return result;
}

// The real, committed calculation. `employerClassification` is the (already computed, once
// per render) output of classifyEmployerOvertime() for this shift's employer — every other
// shift that employer has on the same day/week has already been taken into account.
function calculateShiftPay(shift, employerClassification) {
  const transport = Number(shift.transport || 0);
  const otherAllowance = Number(shift.otherAllowance || 0);
  const isStatutoryHoliday = !!shift.isStatutoryHoliday;
  const lateNightRate = shift.lateNightRate != null ? shift.lateNightRate : DEFAULT_RATES.lateNight;
  const overtimeRate = shift.overtimeRate != null ? shift.overtimeRate : DEFAULT_RATES.overtime;
  const holidayRate = shift.holidayRate != null ? shift.holidayRate : DEFAULT_RATES.holiday;

  let minutes, exp;
  if (isStatutoryHoliday) {
    exp = expandShiftMinutes(shift);
    minutes = exp.minutes.map((m) => ({ ...m, bucket: "holiday" }));
  } else {
    const cls = (employerClassification || {})[shift.id];
    if (cls) { minutes = cls.minutes; exp = cls.exp; }
    else { exp = expandShiftMinutes(shift); minutes = exp.minutes.map((m) => ({ ...m, bucket: "normal" })); }
  }

  let base = 0, lateNightExtra = 0, overtimeExtra = 0, holidayExtra = 0;
  let lateNightMin = 0, scheduledOtMin = 0, overtimeMin = 0, holidayMin = 0;
  const lateNightMinutes = [], overtimeMinutes = [], holidayMinutes = [];

  minutes.forEach((min) => {
    const perMinWage = min.wage / 60;
    base += perMinWage;
    if (isLateNightMinute(min.clockMin)) {
      lateNightExtra += perMinWage * lateNightRate; lateNightMin++;
      lateNightMinutes.push({ clockMin: min.clockMin, wage: min.wage });
    }
    if (min.bucket === "holiday") {
      holidayExtra += perMinWage * holidayRate; holidayMin++;
      holidayMinutes.push({ clockMin: min.clockMin, wage: min.wage });
    } else if (min.bucket === "daily_legal_ot" || min.bucket === "weekly_legal_ot") {
      overtimeExtra += perMinWage * overtimeRate; overtimeMin++;
      overtimeMinutes.push({ clockMin: min.clockMin, wage: min.wage });
    } else if (min.bucket === "scheduled_ot") {
      scheduledOtMin++; // 所定内残業: 割増なし、通常単価のまま base に含まれている
    }
  });
  const netMin = exp.netMin;
  const normalMin = Math.max(0, netMin - overtimeMin - scheduledOtMin - holidayMin);

  const grossPay = base + lateNightExtra + overtimeExtra + holidayExtra;
  let netPayBeforeExtras = grossPay;
  if (!exp.preciseBreak && exp.breakMin > 0 && exp.rawLen > 0) {
    const perMin = grossPay / exp.rawLen;
    netPayBeforeExtras = Math.max(0, grossPay - exp.breakMin * perMin);
  }
  const netPay = netPayBeforeExtras + transport + otherAllowance;

  return {
    totalMin: exp.rawLen, netMin, normalMin, base, lateNightExtra, overtimeExtra, holidayExtra,
    lateNightMin, scheduledOtMin, overtimeMin, holidayMin, transport, otherAllowance, netPay,
    preciseBreak: exp.preciseBreak,
    lateNightRanges: minutesToRanges(lateNightMinutes.map((m) => m.clockMin)),
    overtimeRanges: minutesToRanges(overtimeMinutes.map((m) => m.clockMin)),
    holidayRanges: minutesToRanges(holidayMinutes.map((m) => m.clockMin)),
    lateNightFormula: minutesToFormulaLines(lateNightMinutes, lateNightRate),
    overtimeFormula: minutesToFormulaLines(overtimeMinutes, overtimeRate),
    holidayFormula: minutesToFormulaLines(holidayMinutes, holidayRate),
    breakdown: { base, lateNightExtra, overtimeExtra, holidayExtra },
  };
}

// Groups an employer's shifts and runs classifyEmployerOvertime once. Call this from the
// scope that has ALL shifts (not just the visible month) so weeks spanning a month boundary
// are judged correctly, then pass the result into calculateShiftPay for each shift.
function buildEmployerClassifications(allShifts) {
  const byEmployer = {};
  allShifts.forEach((s) => { (byEmployer[s.employer] = byEmployer[s.employer] || []).push(s); });
  const result = {};
  Object.keys(byEmployer).forEach((emp) => { result[emp] = classifyEmployerOvertime(byEmployer[emp]); });
  return result;
}

function payFor(shift, employerClassifications) {
  return calculateShiftPay(shift, (employerClassifications || {})[shift.employer]);
}

// Kept as an alias for any leftover call sites; behaves like calculateShiftPay with no
// cross-shift context (same as estimateShiftPay).
function shiftTotals(shift) {
  return estimateShiftPay(shift);
}

// Aggregates a set of shifts (already filtered to one month) into the payslip totals used
// by the 給与 tab. Pure function — no React, no rounding until display.
function calculateMonthlyPay(monthShifts, employerClassifications) {
  let base = 0, overtime = 0, lateNight = 0, holiday = 0, transport = 0, otherAllowance = 0;
  let baseMin = 0, normalMin = 0, overtimeMin = 0, scheduledOtMin = 0, lateNightMin = 0, holidayMin = 0;
  const contributors = { overtime: [], lateNight: [], holiday: [], transport: [], otherAllowance: [] };
  monthShifts.forEach((s) => {
    const t = payFor(s, employerClassifications);
    base += t.base; overtime += t.overtimeExtra; lateNight += t.lateNightExtra;
    holiday += t.holidayExtra; transport += t.transport; otherAllowance += t.otherAllowance;
    baseMin += t.netMin; normalMin += t.normalMin; overtimeMin += t.overtimeMin; scheduledOtMin += t.scheduledOtMin;
    lateNightMin += t.lateNightMin; holidayMin += t.holidayMin;
    if (t.overtimeExtra > 0) contributors.overtime.push({ shift: s, amount: t.overtimeExtra, min: t.overtimeMin, ranges: t.overtimeRanges, formula: t.overtimeFormula });
    if (t.lateNightExtra > 0) contributors.lateNight.push({ shift: s, amount: t.lateNightExtra, min: t.lateNightMin, ranges: t.lateNightRanges, formula: t.lateNightFormula });
    if (t.holidayExtra > 0) contributors.holiday.push({ shift: s, amount: t.holidayExtra, min: t.holidayMin, ranges: t.holidayRanges, formula: t.holidayFormula });
    if (t.transport > 0) contributors.transport.push({ shift: s, amount: t.transport });
    if (t.otherAllowance > 0) contributors.otherAllowance.push({ shift: s, amount: t.otherAllowance });
  });
  const grossTotal = base + overtime + lateNight + holiday + transport + otherAllowance;
  return { base, overtime, lateNight, holiday, transport, otherAllowance, grossTotal, baseMin, normalMin, overtimeMin, scheduledOtMin, lateNightMin, holidayMin, contributors };
}

// Groups shifts into Mon–Sun weeks and sums net worked minutes, plus how many of those
// minutes actually became weekly-legal-overtime (via classifyEmployerOvertime — this DOES
// feed back into pay now, unlike the old purely-informational version).
function calculateWeeklyHours(shifts, employerClassifications) {
  const map = {};
  shifts.forEach((s) => {
    const wk = mondayOfWeek(s.date);
    const t = payFor(s, employerClassifications);
    if (!map[wk]) map[wk] = { totalMin: 0, weeklyLegalOtMin: 0, items: [] };
    map[wk].totalMin += t.netMin;
    if (!s.isStatutoryHoliday) {
      const cls = (employerClassifications || {})[s.employer];
      const shiftCls = cls && cls[s.id];
      if (shiftCls) {
        const weeklyOtHere = shiftCls.minutes.filter((m) => m.bucket === "weekly_legal_ot").length;
        map[wk].weeklyLegalOtMin += weeklyOtHere;
      }
    }
    map[wk].items.push({ shift: s, min: t.netMin });
  });
  return map;
}

function profileDefaults(employerName, profiles) {
  const p = (profiles || []).find((pr) => pr.name === employerName);
  if (!p) return { scheduledMin: DAILY_OT_THRESHOLD, lateNightRate: DEFAULT_RATES.lateNight, overtimeRate: DEFAULT_RATES.overtime, holidayRate: DEFAULT_RATES.holiday };
  return {
    scheduledMin: (p.scheduledHours || 8) * 60,
    lateNightRate: p.lateNightRate, overtimeRate: p.overtimeRate, holidayRate: p.holidayRate,
  };
}



// Soft, non-blocking sanity checks. Unlike validateShift (which blocks saving on clear
// input errors), these flag results that are *possible* but unusual — likely typos.
function detectShiftAnomalies(shift, calc) {
  const warnings = [];
  if (calc.totalMin > 16 * 60) warnings.push(`1回の勤務が${(calc.totalMin / 60).toFixed(1)}時間と長時間になっています。時刻の入力ミスがないか確認してください`);
  if (calc.netMin > 0 && calc.netPay <= 0) warnings.push("勤務時間があるのに給与が¥0円です。時給や休憩の設定を確認してください");
  if (calc.overtimeMin > 8 * 60) warnings.push(`残業時間が${(calc.overtimeMin / 60).toFixed(1)}時間と長くなっています。所定労働時間の設定を確認してください`);
  return warnings;
}

function segmentAbsoluteRange(seg) {
  const s = toMin(seg.start);
  let e = toMin(seg.end);
  if (e <= s) e += 1440;
  return [s, e];
}

function validateShift({ segments, breakMin, breakStart, lateNightRate, overtimeRate, holidayRate }) {
  const errors = [];
  segments.forEach((seg, i) => {
    const dur = calcMinutes(seg.start, seg.end);
    if (dur <= 0) errors.push(`時間帯${i + 1}: 終了時刻が開始時刻と同じか前になっています`);
    if (!seg.wage || Number(seg.wage) <= 0) errors.push(`時間帯${i + 1}: 時給が0円以下になっています。1円以上を入力してください`);
  });
  for (let i = 0; i < segments.length; i++) {
    for (let j = i + 1; j < segments.length; j++) {
      const [s1, e1] = segmentAbsoluteRange(segments[i]);
      const [s2, e2] = segmentAbsoluteRange(segments[j]);
      if (s1 < e2 && s2 < e1) errors.push(`時間帯${i + 1}と時間帯${j + 1}の勤務時間が重複しています`);
    }
  }
  const totalMin = segments.reduce((sum, seg) => sum + Math.max(0, calcMinutes(seg.start, seg.end)), 0);
  if (Number(breakMin) > totalMin) errors.push("休憩時間が勤務時間を超えています");
  if (breakStart && Number(breakMin) > 0) {
    const allMinutes = expandSegments(segments, "", 0);
    const workedSet = new Set(allMinutes.map((m) => m.clockMin));
    const bs = toMin(breakStart);
    const startsInside = workedSet.has(bs) || workedSet.has(bs + 1440);
    if (!startsInside) {
      errors.push("休憩開始時刻が勤務時間外です");
    } else {
      // Every minute of the break window must also fall inside a worked segment —
      // otherwise the break would run past the end of the shift.
      const base = workedSet.has(bs) ? bs : bs + 1440;
      let allInside = true;
      for (let t = base; t < base + Number(breakMin); t++) {
        if (!workedSet.has(t)) { allInside = false; break; }
      }
      if (!allInside) errors.push("休憩時間が勤務時間の範囲を超えて設定されています");
    }
  }
  [["深夜割増率", lateNightRate], ["残業割増率", overtimeRate], ["法定休日割増率", holidayRate]].forEach(([label, rate]) => {
    if (rate != null && rate < 0) errors.push(`${label}にマイナスの値は設定できません`);
  });
  return errors;
}

function segmentsSummary(segments) {
  return (segments || []).map((seg) => `${seg.start}–${seg.end} ¥${seg.wage}`).join(" ・ ");
}
function yen(n) {
  return "¥" + Math.round(n).toLocaleString("ja-JP");
}
function hrs(min) {
  return (min / 60).toFixed(1) + "h";
}
function monthLabel(key) {
  const [y, m] = key.split("-");
  return `${y}年${Number(m)}月`;
}
function shiftMonth(key, delta) {
  const [y, m] = key.split("-").map(Number);
  const d = new Date(y, m - 1 + delta, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}
function blankSegment() {
  return { id: uid(), start: "09:00", end: "17:00", wage: "1200" };
}
function breakHint(totalMin) {
  if (totalMin >= 480) return "8時間超の勤務のため、法律上は休憩60分以上が必要です";
  if (totalMin > 360) return "6時間超の勤務のため、法律上は休憩45分以上が必要です";
  return "";
}
function mondayOfWeek(dateStr) {
  const d = new Date(dateStr + "T00:00:00");
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setDate(d.getDate() + diff);
  return ymd(d);
}
function weekLabel(mondayStr) {
  const d = new Date(mondayStr + "T00:00:00");
  const e = new Date(d);
  e.setDate(e.getDate() + 6);
  return `${d.getMonth() + 1}/${d.getDate()}〜${e.getMonth() + 1}/${e.getDate()}`;
}

function downloadFile(filename, content, mime) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = filename;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function toCSV(rows) {
  return rows.map((r) => r.map((v) => `"${String(v ?? "").replace(/"/g, '""')}"`).join(",")).join("\r\n");
}

// --- カレンダー(.ics)出力 -------------------------------------------------------------
// シフトを iCalendar 形式に変換する。VALARM で「開始◯分前」のリマインダーを埋め込むので、
// iPhone/Androidの標準カレンダーアプリに取り込めば、OS本来の通知機能で確実にリマインドされる。
function icsDateTime(dateStr, hhmm, dayOffset = 0) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const [h, mi] = hhmm.split(":").map(Number);
  const dt = new Date(y, m - 1, d + dayOffset, h, mi, 0);
  const pad = (n) => String(n).padStart(2, "0");
  return `${dt.getFullYear()}${pad(dt.getMonth() + 1)}${pad(dt.getDate())}T${pad(dt.getHours())}${pad(dt.getMinutes())}00`;
}

function shiftsToICS(shifts, reminderMinutes) {
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//シフトマネージャー//JA"];
  shifts.forEach((s) => {
    if (!s.segments || s.segments.length === 0) return;
    const start = s.segments[0].start;
    const last = s.segments[s.segments.length - 1];
    const endToMin = toMin(last.end);
    const dayOffset = endToMin <= toMin(start) ? 1 : 0; // 日をまたぐ場合
    const dtStart = icsDateTime(s.date, start);
    const dtEnd = icsDateTime(s.date, last.end, dayOffset);
    lines.push(
      "BEGIN:VEVENT",
      `UID:${s.id}@shift-manager`,
      `DTSTART:${dtStart}`,
      `DTEND:${dtEnd}`,
      `SUMMARY:${s.employer}のシフト`,
      `DESCRIPTION:${segmentsSummary(s.segments)}`,
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      `DESCRIPTION:まもなくシフト開始（${s.employer}）`,
      `TRIGGER:-PT${reminderMinutes}M`,
      "END:VALARM",
      "END:VEVENT"
    );
  });
  lines.push("END:VCALENDAR");
  return lines.join("\r\n");
}

export default function App() {
  const [loading, setLoading] = useState(true);
  const [shifts, setShifts] = useState([]);
  const [expenses, setExpenses] = useState([]);
  const [templates, setTemplates] = useState([]);
  const [deductions, setDeductions] = useState([]);
  const [employerProfiles, setEmployerProfiles] = useState([]);
  const [actualPay, setActualPay] = useState({});
  const [weeklyThresholdHours, setWeeklyThresholdHours] = useState(40);
  const [darkMode, setDarkMode] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [notifyEnabled, setNotifyEnabled] = useState(false);
  const [reminderMinutes, setReminderMinutes] = useState(60);
  const [notifyPermission, setNotifyPermission] = useState("default");
  const [tab, setTab] = useState("overview");
  const [focusAddShift, setFocusAddShift] = useState(0);
  const today = new Date();
  const [month, setMonth] = useState(`${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}`);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try { const s = await storage.get("shifts-data"); setShifts(s ? JSON.parse(s.value).map(migrateShift) : []); } catch (e) { setShifts([]); }
      try { const ex = await storage.get("expenses-data"); setExpenses(ex ? JSON.parse(ex.value) : []); } catch (e) { setExpenses([]); }
      try { const t = await storage.get("shift-templates"); setTemplates(t ? JSON.parse(t.value) : []); } catch (e) { setTemplates([]); }
      try { const d = await storage.get("deductions-data"); setDeductions(d ? JSON.parse(d.value).map(migrateDeduction) : []); } catch (e) { setDeductions([]); }
      try { const ep = await storage.get("employer-profiles"); setEmployerProfiles(ep ? JSON.parse(ep.value).map(migrateEmployer) : []); } catch (e) { setEmployerProfiles([]); }
      try {
        const ap = await storage.get("actual-pay");
        const raw = ap ? JSON.parse(ap.value) : {};
        const fixed = {};
        Object.keys(raw).forEach((k) => { fixed[k] = migrateActualPay(raw[k]); });
        setActualPay(fixed);
      } catch (e) { setActualPay({}); }
      try {
        const ws = await storage.get("weekly-threshold");
        setWeeklyThresholdHours(ws ? JSON.parse(ws.value) : 40);
      } catch (e) { setWeeklyThresholdHours(40); }
      try {
        const dm = await storage.get("dark-mode");
        setDarkMode(dm ? JSON.parse(dm.value) : false);
      } catch (e) { setDarkMode(false); }
      try {
        const ns = await storage.get("notify-settings");
        const parsed = ns ? JSON.parse(ns.value) : null;
        if (parsed) { setNotifyEnabled(!!parsed.enabled); setReminderMinutes(parsed.minutes || 60); }
      } catch (e) { /* ignore */ }
      try {
        if (typeof Notification !== "undefined") setNotifyPermission(Notification.permission);
      } catch (e) { setNotifyPermission("unsupported"); }
      setLoading(false);
    })();
  }, []);

  async function persist(key, next, setter) {
    setter(next);
    for (let attempt = 0; attempt < 2; attempt++) {
      try { await storage.set(key, JSON.stringify(next)); setError(""); return; }
      catch (e) {
        if (attempt === 1) setError("端末への保存に失敗しました（この画面を閉じると内容が消える可能性があります）");
        else await new Promise((r) => setTimeout(r, 400));
      }
    }
  }
  async function saveShifts(next) { await persist("shifts-data", next, setShifts); }
  async function saveExpenses(next) { await persist("expenses-data", next, setExpenses); }
  async function saveTemplates(next) { await persist("shift-templates", next, setTemplates); }
  async function saveDeductions(next) { await persist("deductions-data", next, setDeductions); }
  async function saveEmployerProfiles(next) { await persist("employer-profiles", next, setEmployerProfiles); }
  async function saveActualPay(next) { await persist("actual-pay", next, setActualPay); }
  async function saveWeeklyThreshold(next) { await persist("weekly-threshold", next, setWeeklyThresholdHours); }
  async function saveDarkMode(next) { await persist("dark-mode", next, setDarkMode); }

  async function saveNotifySettings(enabled, minutes) {
    setNotifyEnabled(enabled);
    setReminderMinutes(minutes);
    try { await storage.set("notify-settings", JSON.stringify({ enabled, minutes })); } catch (e) { /* best-effort */ }
  }

  async function requestNotifyPermission() {
    try {
      if (typeof Notification === "undefined") { setNotifyPermission("unsupported"); return; }
      const result = await Notification.requestPermission();
      setNotifyPermission(result);
    } catch (e) {
      setNotifyPermission("unsupported");
    }
  }

  // Best-effort only: fires while this tab/artifact is actually open. Schedules a browser
  // notification for each of TODAY's upcoming shifts, `reminderMinutes` before they start.
  // Cannot fire once the app is closed — see the settings panel for the reliable alternative
  // (calendar export).
  useEffect(() => {
    if (!notifyEnabled || notifyPermission !== "granted") return;
    if (typeof Notification === "undefined") return;
    const todayStr = todayYMD();
    const todays = shifts.filter((s) => s.date === todayStr && s.segments && s.segments.length);
    const timers = [];
    const now = Date.now();
    todays.forEach((s) => {
      const [h, mi] = s.segments[0].start.split(":").map(Number);
      const startTime = new Date();
      startTime.setHours(h, mi, 0, 0);
      const fireAt = startTime.getTime() - reminderMinutes * 60000;
      const delay = fireAt - now;
      if (delay > 0 && delay < 24 * 60 * 60 * 1000) {
        const t = setTimeout(() => {
          try { new Notification("まもなくシフト開始", { body: `${s.employer} ${s.segments[0].start}〜`, tag: s.id }); } catch (e) { /* ignore */ }
        }, delay);
        timers.push(t);
      }
    });
    return () => timers.forEach(clearTimeout);
  }, [notifyEnabled, notifyPermission, reminderMinutes, shifts]);


  const monthShifts = useMemo(() => shifts.filter((s) => s.date.slice(0, 7) === month).sort((a, b) => a.date.localeCompare(b.date)), [shifts, month]);
  const monthExpenses = useMemo(() => expenses.filter((e) => e.date.slice(0, 7) === month).sort((a, b) => a.date.localeCompare(b.date)), [expenses, month]);
  const monthDeductions = useMemo(() => deductions.filter((d) => d.month === month), [deductions, month]);

  // Computed once from ALL shifts (not just the visible month) so that a week spanning a
  // month boundary is still judged as a single week. Every displayed pay figure flows
  // through this — see calculateShiftPay / payFor.
  const employerClassifications = useMemo(() => buildEmployerClassifications(shifts), [shifts]);

  const payslip = useMemo(() => calculateMonthlyPay(monthShifts, employerClassifications), [monthShifts, employerClassifications]);

  const weeklyBuckets = useMemo(() => {
    const map = calculateWeeklyHours(shifts, employerClassifications);
    return Object.entries(map)
      .filter(([wk]) => {
        const start = wk;
        const endDate = new Date(wk + "T00:00:00");
        endDate.setDate(endDate.getDate() + 6);
        const end = ymd(endDate);
        return start.slice(0, 7) === month || end.slice(0, 7) === month;
      })
      .sort((a, b) => a[0].localeCompare(b[0]));
  }, [shifts, month, employerClassifications]);

  const monthIncome = payslip.grossTotal;
  const monthExpenseTotal = monthExpenses.reduce((sum, e) => sum + Number(e.amount), 0);
  const deductionsTotal = monthDeductions.reduce((sum, d) => sum + Number(d.amount), 0);
  const netIncome = monthIncome - deductionsTotal;
  const balance = netIncome - monthExpenseTotal;

  const prevMonthShifts = useMemo(() => {
    const prev = shiftMonth(month, -1);
    return shifts.filter((s) => s.date.slice(0, 7) === prev);
  }, [shifts, month]);
  const prevMonthIncome = useMemo(() => calculateMonthlyPay(prevMonthShifts, employerClassifications).grossTotal, [prevMonthShifts, employerClassifications]);
  const incomeAnomaly = useMemo(() => {
    if (prevMonthIncome <= 0 || monthIncome <= 0) return null;
    const diffRatio = (monthIncome - prevMonthIncome) / prevMonthIncome;
    if (Math.abs(diffRatio) < 0.4) return null;
    return { diffRatio, prevMonthIncome };
  }, [monthIncome, prevMonthIncome]);

  const byEmployer = useMemo(() => {
    const map = {};
    monthShifts.forEach((s) => {
      const { netMin, netPay } = payFor(s, employerClassifications);
      if (!map[s.employer]) map[s.employer] = { minutes: 0, pay: 0 };
      map[s.employer].minutes += netMin;
      map[s.employer].pay += netPay;
    });
    return Object.entries(map);
  }, [monthShifts, employerClassifications]);

  const byCategory = useMemo(() => {
    const map = {};
    monthExpenses.forEach((e) => { map[e.category] = (map[e.category] || 0) + Number(e.amount); });
    return Object.entries(map).sort((a, b) => b[1] - a[1]);
  }, [monthExpenses]);

  const maxCat = byCategory.length ? byCategory[0][1] : 1;
  const employerNames = useMemo(() => [...new Set(shifts.map((s) => s.employer).filter(Boolean))], [shifts]);

  function exportJSON() {
    const payload = { shifts, expenses, templates, deductions, employerProfiles, actualPay, exportedAt: new Date().toISOString() };
    downloadFile(`shift-manager-backup-${month}.json`, JSON.stringify(payload, null, 2), "application/json");
  }
  function exportShiftsCSV() {
    const rows = [["日付", "勤務先", "時間帯", "休憩(分)", "交通費", "法定休日", "見込み給与"]];
    shifts.forEach((s) => {
      const t = payFor(s, employerClassifications);
      rows.push([s.date, s.employer, segmentsSummary(s.segments), s.breakMin, s.transport, s.isStatutoryHoliday ? "はい" : "いいえ", Math.round(t.netPay)]);
    });
    downloadFile("shifts.csv", toCSV(rows), "text/csv");
  }
  function exportExpensesCSV() {
    const rows = [["日付", "カテゴリ", "金額", "メモ"]];
    expenses.forEach((e) => rows.push([e.date, e.category, e.amount, e.memo || ""]));
    downloadFile("expenses.csv", toCSV(rows), "text/csv");
  }
  function importJSON(file) {
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const data = JSON.parse(reader.result);
        if (Array.isArray(data.shifts)) saveShifts([...shifts, ...data.shifts.map((s) => ({ ...migrateShift(s), id: uid() }))]);
        if (Array.isArray(data.expenses)) saveExpenses([...expenses, ...data.expenses.map((e) => ({ ...e, id: uid() }))]);
        if (Array.isArray(data.templates)) saveTemplates([...templates, ...data.templates.map((t) => ({ ...t, id: uid() }))]);
        if (Array.isArray(data.deductions)) saveDeductions([...deductions, ...data.deductions.map((d) => ({ ...migrateDeduction(d), id: uid() }))]);
        if (Array.isArray(data.employerProfiles)) {
          const names = new Set(employerProfiles.map((p) => p.name));
          const toAdd = data.employerProfiles.filter((p) => !names.has(p.name)).map((p) => ({ ...migrateEmployer(p), id: uid() }));
          if (toAdd.length) saveEmployerProfiles([...employerProfiles, ...toAdd]);
        }
        if (data.actualPay) {
          const fixed = {}; Object.keys(data.actualPay).forEach((k) => { fixed[k] = migrateActualPay(data.actualPay[k]); });
          saveActualPay({ ...actualPay, ...fixed });
        }
        setError("");
      } catch (e) { setError("読み込みに失敗しました。ファイル形式を確認してください"); }
    };
    reader.readAsText(file);
  }

  if (loading) {
    return (<div className="app-shell"><style>{STYLE}</style><div className="loading">読み込み中…</div></div>);
  }

  return (
    <div className={"app-shell" + (darkMode ? " dark" : "")}>
      <style>{STYLE}</style>
      <header className="app-header">
        <span className="app-title">シフトマネージャー</span>
        <div className="header-actions">
          <button className="theme-toggle" aria-label="設定" onClick={() => setShowSettings(true)}>
            <Settings size={15} />
          </button>
          <button className="theme-toggle" aria-label="ダークモード切り替え" onClick={() => saveDarkMode(!darkMode)}>
            {darkMode ? <Sun size={15} /> : <Moon size={15} />}
          </button>
          <div className="month-nav">
            <button aria-label="前の月" onClick={() => setMonth(shiftMonth(month, -1))}><ChevronLeft size={16} /></button>
            <span className="month-label">{monthLabel(month)}</span>
            <button aria-label="次の月" onClick={() => setMonth(shiftMonth(month, 1))}><ChevronRight size={16} /></button>
          </div>
        </div>
      </header>

      {showSettings && (
        <SettingsPanel
          onClose={() => setShowSettings(false)}
          notifyEnabled={notifyEnabled} reminderMinutes={reminderMinutes} notifyPermission={notifyPermission}
          onToggleNotify={(v) => saveNotifySettings(v, reminderMinutes)}
          onChangeReminderMinutes={(v) => saveNotifySettings(notifyEnabled, v)}
          onRequestPermission={requestNotifyPermission}
          onExportMonthICS={() => {
            const ics = shiftsToICS(monthShifts, reminderMinutes);
            downloadFile(`shifts-${month}.ics`, ics, "text/calendar");
          }}
          onExportAllICS={() => {
            const ics = shiftsToICS(shifts, reminderMinutes);
            downloadFile("shifts-all.ics", ics, "text/calendar");
          }}
          monthShiftCount={monthShifts.length}
          totalShiftCount={shifts.length}
        />
      )}

      <main className="content">
        {error && <div className="error-banner">{error}</div>}

        {tab === "overview" && (
          <>
            <div className="hero-card">
              <span className="hero-label">今月の差引残高</span>
              <span className="hero-amount">{(balance >= 0 ? "" : "−") + yen(Math.abs(balance))}</span>
              <div className="hero-chips">
                <span className="hero-chip up"><TrendingUp size={13} />{yen(netIncome)}</span>
                <span className="hero-chip down"><TrendingDown size={13} />{yen(monthExpenseTotal)}</span>
              </div>
              {deductionsTotal > 0 && <span className="hero-note">総支給 {yen(monthIncome)}／控除 −{yen(deductionsTotal)}</span>}
            </div>

            {incomeAnomaly && (
              <div className="anomaly-banner">
                <Info size={14} />
                <span>先月（{yen(incomeAnomaly.prevMonthIncome)}）から{incomeAnomaly.diffRatio >= 0 ? "大きく増えて" : "大きく減って"}います（{incomeAnomaly.diffRatio >= 0 ? "+" : ""}{(incomeAnomaly.diffRatio * 100).toFixed(0)}%）。シフトの記録漏れや入力ミスがないか確認してみてください。</span>
              </div>
            )}

            {byEmployer.length > 0 && (
              <div className="card">
                <h3 className="card-title">勤務先別の給与</h3>
                {byEmployer.map(([name, v]) => (
                  <div className="list-row" key={name}><span className="list-row-label">{name}</span><span className="list-row-value up">{yen(v.pay)}</span></div>
                ))}
              </div>
            )}

            {byCategory.length > 0 && (
              <div className="card">
                <h3 className="card-title">支出カテゴリ別</h3>
                {byCategory.map(([cat, amt]) => (
                  <div className="bar-row" key={cat}>
                    <div className="bar-row-top">
                      <span className="bar-name"><span className="cat-dot" style={{ background: CAT_COLORS[cat] || "#999" }} />{cat}</span>
                      <span className="bar-amount">{yen(amt)}</span>
                    </div>
                    <div className="bar-track"><div className="bar-fill" style={{ width: `${(amt / maxCat) * 100}%`, background: CAT_COLORS[cat] || "#999" }} /></div>
                  </div>
                ))}
              </div>
            )}

            {monthShifts.length === 0 && monthExpenses.length === 0 && <div className="empty-card">この月の記録はまだありません。下のタブから追加してください。</div>}

            <DataManagementCard onExportJSON={exportJSON} onExportShiftsCSV={exportShiftsCSV} onExportExpensesCSV={exportExpensesCSV} onImportJSON={importJSON} />
          </>
        )}

        {tab === "shifts" && (
          <ShiftsPanel
            month={month} monthShifts={monthShifts} allShifts={shifts} templates={templates}
            employerNames={employerNames} employerProfiles={employerProfiles} focusSignal={focusAddShift}
            employerClassifications={employerClassifications}
            onAdd={(entry) => saveShifts([...shifts, { ...entry, id: uid() }])}
            onUpdate={(id, entry) => saveShifts(shifts.map((s) => (s.id === id ? { ...entry, id } : s)))}
            onDelete={(id) => saveShifts(shifts.filter((s) => s.id !== id))}
            onSaveTemplate={(tpl) => saveTemplates([...templates, { ...tpl, id: uid() }])}
            onDeleteTemplate={(id) => saveTemplates(templates.filter((t) => t.id !== id))}
            onSaveEmployerProfile={(prof) => {
              const existing = employerProfiles.find((p) => p.name === prof.name);
              if (existing) saveEmployerProfiles(employerProfiles.map((p) => (p.name === prof.name ? { ...p, ...prof } : p)));
              else saveEmployerProfiles([...employerProfiles, { ...prof, id: uid() }]);
            }}
            onDeleteEmployerProfile={(id) => saveEmployerProfiles(employerProfiles.filter((p) => p.id !== id))}
          />
        )}

        {tab === "wage" && (
          <WageTab
            month={month} payslip={payslip} weeklyBuckets={weeklyBuckets} monthDeductions={monthDeductions}
            deductionsTotal={deductionsTotal} monthIncome={monthIncome} netIncome={netIncome}
            hasApproximateBreak={monthShifts.some((s) => Number(s.breakMin) > 0 && !s.breakStart)}
            employerProfiles={employerProfiles}
            actualPay={actualPay[month]} onSetActualPay={(v) => saveActualPay({ ...actualPay, [month]: v })}
            onAddDeduction={(entry) => {
              // Upsert by (month, category) — except "その他控除", where multiple free-form
              // entries make sense (e.g. two separate one-off deductions in the same month).
              if (entry.category !== "その他控除") {
                const existing = deductions.find((d) => d.month === month && d.category === entry.category);
                if (existing) {
                  saveDeductions(deductions.map((d) => (d.id === existing.id ? { ...d, amount: entry.amount, note: entry.note } : d)));
                  return;
                }
              }
              saveDeductions([...deductions, { ...entry, id: uid(), month }]);
            }}
            onDeleteDeduction={(id) => saveDeductions(deductions.filter((d) => d.id !== id))}
            weeklyThresholdHours={weeklyThresholdHours} onSetWeeklyThresholdHours={saveWeeklyThreshold}
          />
        )}

        {tab === "expenses" && (
          <ExpensesPanel monthExpenses={monthExpenses}
            onAdd={(entry) => saveExpenses([...expenses, { ...entry, id: uid() }])}
            onDelete={(id) => saveExpenses(expenses.filter((e) => e.id !== id))} />
        )}
      </main>

      <button className="fab" aria-label="シフトを追加" onClick={() => { setTab("shifts"); setFocusAddShift((n) => n + 1); }}><Plus size={24} /></button>

      <nav className="bottom-nav">
        <NavButton active={tab === "overview"} onClick={() => setTab("overview")} icon={<Home size={20} />} label="概要" />
        <NavButton active={tab === "shifts"} onClick={() => setTab("shifts")} icon={<Clock3 size={20} />} label="シフト" />
        <NavButton active={tab === "wage"} onClick={() => setTab("wage")} icon={<Wallet size={20} />} label="給与" />
        <NavButton active={tab === "expenses"} onClick={() => setTab("expenses")} icon={<Receipt size={20} />} label="支出" />
      </nav>
    </div>
  );
}

function NavButton({ active, onClick, icon, label }) {
  return (<button className={"nav-btn" + (active ? " active" : "")} onClick={onClick}><span className="nav-icon">{icon}</span><span className="nav-label">{label}</span></button>);
}

function DataManagementCard({ onExportJSON, onExportShiftsCSV, onExportExpensesCSV, onImportJSON }) {
  const fileRef = useRef(null);
  return (
    <div className="card">
      <h3 className="card-title">データのバックアップ</h3>
      <p className="pattern-hint" style={{ marginBottom: 12 }}>機種変更などに備えて、データを書き出し・読み込みできます。外部サーバーには送信されません。</p>
      <div className="data-btn-row">
        <button className="data-btn" onClick={onExportJSON}><Download size={14} />JSONで全データ書き出し</button>
        <button className="data-btn" onClick={onExportShiftsCSV}><Download size={14} />シフトCSV</button>
        <button className="data-btn" onClick={onExportExpensesCSV}><Download size={14} />支出CSV</button>
        <button className="data-btn" onClick={() => fileRef.current?.click()}><Upload size={14} />JSONを読み込む</button>
        <input ref={fileRef} type="file" accept="application/json" style={{ display: "none" }} onChange={(e) => { if (e.target.files[0]) onImportJSON(e.target.files[0]); e.target.value = ""; }} />
      </div>
    </div>
  );
}

function CalendarMonth({ month, monthShifts, employerClassifications, selectedDate, onSelectDate, onAddDate }) {
  const [y, m] = month.split("-").map(Number);
  const firstDay = new Date(y, m - 1, 1);
  const daysInMonth = new Date(y, m, 0).getDate();
  const startOffset = firstDay.getDay();
  const lastTap = useRef({ date: null, time: 0 });

  const byDate = useMemo(() => {
    const map = {};
    monthShifts.forEach((s) => {
      const { netPay } = payFor(s, employerClassifications);
      if (!map[s.date]) map[s.date] = { count: 0, pay: 0, employers: [] };
      map[s.date].count += 1; map[s.date].pay += netPay;
      if (!map[s.date].employers.includes(s.employer)) map[s.date].employers.push(s.employer);
    });
    return map;
  }, [monthShifts, employerClassifications]);

  const cells = [];
  for (let i = 0; i < startOffset; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  function handleTap(dateStr) {
    const now = Date.now();
    if (lastTap.current.date === dateStr && now - lastTap.current.time < 400) {
      lastTap.current = { date: null, time: 0 };
      onAddDate(dateStr);
    } else {
      lastTap.current = { date: dateStr, time: now };
      onSelectDate(dateStr);
    }
  }

  return (
    <div className="calendar-card">
      <div className="calendar-weekdays">{WEEKDAYS.map((w, i) => <span key={w} className={"weekday" + (i === 0 ? " sun" : i === 6 ? " sat" : "")}>{w}</span>)}</div>
      <div className="calendar-grid">
        {cells.map((d, i) => {
          if (d === null) return <div className="cal-cell empty" key={"e" + i} />;
          const dateStr = `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
          const info = byDate[dateStr];
          const isSelected = selectedDate === dateStr;
          const dow = new Date(y, m - 1, d).getDay();
          return (
            <button key={dateStr} className={"cal-cell" + (isSelected ? " selected" : "") + (info ? " has-shift" : "")} onClick={() => handleTap(dateStr)}>
              <span className={"cal-day" + (dow === 0 ? " sun" : dow === 6 ? " sat" : "")}>{d}</span>
              {info && <span className="cal-emp">{info.employers.length > 1 ? `${info.employers[0]} +${info.employers.length - 1}` : info.employers[0]}</span>}
            </button>
          );
        })}
      </div>
      <p className="calendar-hint">タップで詳細・ダブルタップで追加</p>
    </div>
  );
}

function DayDetail({ date, dayShifts, employerClassifications, onDelete, onAddClick, onEdit }) {
  if (!date) return null;
  const total = dayShifts.reduce((sum, s) => sum + payFor(s, employerClassifications).netPay, 0);
  const label = `${Number(date.slice(5, 7))}月${Number(date.slice(8, 10))}日`;
  return (
    <div className="card">
      <div className="card-title-row"><h3 className="card-title">{label}の詳細</h3><button className="chip-btn" onClick={onAddClick}><Plus size={13} />追加</button></div>
      {dayShifts.length === 0 && <p className="empty-note">この日のシフトはありません。</p>}
      {dayShifts.map((s) => {
        const { netPay, breakdown, transport, scheduledOtMin, preciseBreak } = payFor(s, employerClassifications);
        const isApprox = Number(s.breakMin) > 0 && !preciseBreak;
        return (
          <div className="entry-card" key={s.id}>
            <div className="entry-accent" style={{ background: s.isStatutoryHoliday ? "#F43F5E" : "#10B981" }} />
            <button className="entry-body entry-body-btn" onClick={() => onEdit(s)}>
              <div className="entry-top"><span className="entry-name">{s.employer}</span><span className="entry-amount up">{yen(netPay)}</span></div>
              <span className="entry-sub">{segmentsSummary(s.segments)}{s.breakMin > 0 ? ` ・ 休${s.breakMin}分` : ""}</span>
              <div className="badge-row">
                <span className={"badge precision" + (isApprox ? " approx" : "")}>{isApprox ? "概算" : "正確"}</span>
                {scheduledOtMin > 0 && <span className="badge scheduled">所定内残業{hrs(scheduledOtMin)}</span>}
                {breakdown.lateNightExtra > 0 && <span className="badge">深夜+{yen(breakdown.lateNightExtra)}</span>}
                {breakdown.overtimeExtra > 0 && <span className="badge">法定残業+{yen(breakdown.overtimeExtra)}</span>}
                {breakdown.holidayExtra > 0 && <span className="badge holiday">法定休日+{yen(breakdown.holidayExtra)}</span>}
                {transport > 0 && <span className="badge transport">交通費+{yen(transport)}</span>}
              </div>
            </button>
            <button className="del-btn" aria-label="削除" onClick={() => onDelete(s.id)}><Trash2 size={14} /></button>
          </div>
        );
      })}
      {dayShifts.length > 0 && <div className="list-row total-row"><span className="list-row-label">この日の合計</span><span className="list-row-value up strong">{yen(total)}</span></div>}
    </div>
  );
}

function TemplateChips({ templates, onPick, onDelete, justAdded }) {
  if (templates.length === 0) return null;
  return (
    <div className="card pattern-card">
      <h3 className="card-title">よく使うフォーマット</h3>
      <p className="pattern-hint">タップでそのままシフトを追加。固定シフトの人は登録しておくと便利です。</p>
      <div className="pattern-scroll">
        {templates.map((t) => (
          <div key={t.id} className={"template-chip" + (justAdded === t.id ? " just-added" : "")}>
            <button className="template-del" aria-label="削除" onClick={() => onDelete(t.id)}><X size={11} /></button>
            <button className="template-main" onClick={() => onPick(t)}>
              <span className="pattern-employer">{t.name || t.employer}</span>
              <span className="pattern-sub">{t.employer}</span>
              {(t.segments || []).map((seg, i) => <span className="pattern-time" key={i}>{seg.start}–{seg.end} ¥{seg.wage}</span>)}
              {t.breakMin > 0 && <span className="pattern-time break">休憩{t.breakMin}分</span>}
              {t.transport > 0 && <span className="pattern-time break">交通費¥{t.transport}</span>}
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function blankFormState() {
  const d = profileDefaults("", []);
  return {
    employer: "", breakMin: "0", breakStart: "", breakEnd: "", transport: "0", otherAllowance: "0",
    isStatutoryHoliday: false, segments: [blankSegment()],
    scheduledMin: d.scheduledMin, lateNightRate: d.lateNightRate, overtimeRate: d.overtimeRate, holidayRate: d.holidayRate,
  };
}

// When both break start and end are set, derive the minute count automatically so the two
// never disagree. Leaves breakMin as-is (manually editable) when only one or neither is set.
function applyBreakTimes(f) {
  if (f.breakStart && f.breakEnd) {
    const mins = calcMinutes(f.breakStart, f.breakEnd);
    return { ...f, breakMin: String(mins) };
  }
  return f;
}

function ShiftsPanel({ month, monthShifts, allShifts, templates, employerNames, employerProfiles, employerClassifications, focusSignal, onAdd, onUpdate, onDelete, onSaveTemplate, onDeleteTemplate, onSaveEmployerProfile, onDeleteEmployerProfile }) {
  const todayStr = todayYMD();
  const [form, setForm] = useState(blankFormState());
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [saveAsTemplate, setSaveAsTemplate] = useState(false);
  const [templateName, setTemplateName] = useState("");
  const [selectedDate, setSelectedDate] = useState(null);
  const [warn, setWarn] = useState([]);
  const [justAdded, setJustAdded] = useState(null);
  const [editingId, setEditingId] = useState(null);
  const formRef = useRef(null);
  const employerInputRef = useRef(null);
  const effectiveDate = selectedDate || todayStr;
  const activeProfile = employerProfiles.find((p) => p.name === form.employer);

  useEffect(() => {
    if (!focusSignal) return;
    setEditingId(null);
    formRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
    setTimeout(() => employerInputRef.current?.focus(), 350);
  }, [focusSignal]);

  function applyProfile(name) {
    const p = employerProfiles.find((pr) => pr.name === name);
    if (!p) return;
    setForm((f) => ({
      ...f,
      segments: f.segments.length === 1 && !f.segments[0]._touched && p.defaultWage ? [{ ...f.segments[0], wage: String(p.defaultWage) }] : f.segments,
      transport: p.defaultTransport ? String(p.defaultTransport) : f.transport,
      otherAllowance: p.otherAllowance ? String(p.otherAllowance) : f.otherAllowance,
      scheduledMin: (p.scheduledHours || 8) * 60,
      lateNightRate: p.lateNightRate, overtimeRate: p.overtimeRate, holidayRate: p.holidayRate,
    }));
  }

  const preview = useMemo(() => estimateShiftPay(form), [form]);
  const anomalies = useMemo(() => detectShiftAnomalies(form, preview), [form, preview]);

  function updateSegment(id, patch) {
    setForm((f) => ({ ...f, segments: f.segments.map((s) => (s.id === id ? { ...s, ...patch, _touched: true } : s)) }));
  }
  function addSegment() {
    setForm((f) => {
      const last = f.segments[f.segments.length - 1];
      return { ...f, segments: [...f.segments, { id: uid(), start: last ? last.end : "17:00", end: "22:00", wage: last ? last.wage : "1200" }] };
    });
  }
  function removeSegment(id) {
    setForm((f) => ({ ...f, segments: f.segments.length > 1 ? f.segments.filter((s) => s.id !== id) : f.segments }));
  }

  function resetForm() {
    setForm(blankFormState());
    setEditingId(null); setSaveAsTemplate(false); setTemplateName(""); setShowAdvanced(false);
  }

  function submit() {
    const errs = [];
    if (!form.employer) errs.push("勤務先を入力してください");
    errs.push(...validateShift(form));
    if (errs.length) { setWarn(errs); return; }
    setWarn([]);
    const cleanSegments = form.segments.map(({ id, _touched, ...rest }) => rest);
    const entry = {
      date: effectiveDate, employer: form.employer, breakMin: form.breakMin, breakStart: form.breakStart, breakEnd: form.breakEnd,
      transport: form.transport, otherAllowance: form.otherAllowance, isStatutoryHoliday: form.isStatutoryHoliday,
      segments: cleanSegments, scheduledMin: form.scheduledMin, lateNightRate: form.lateNightRate,
      overtimeRate: form.overtimeRate, holidayRate: form.holidayRate,
    };
    if (editingId) onUpdate(editingId, entry); else onAdd(entry);
    if (saveAsTemplate) {
      onSaveTemplate({ name: templateName || form.employer, employer: form.employer, breakMin: form.breakMin, breakStart: form.breakStart, breakEnd: form.breakEnd, transport: form.transport, segments: cleanSegments });
    }
    resetForm();
  }

  function handleAddDate(dateStr) {
    setEditingId(null);
    setSelectedDate(dateStr);
    formRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function handleEdit(shift) {
    setEditingId(shift.id);
    setSelectedDate(shift.date);
    setForm({
      employer: shift.employer, breakMin: String(shift.breakMin || 0), breakStart: shift.breakStart || "", breakEnd: shift.breakEnd || "",
      transport: String(shift.transport || 0), otherAllowance: String(shift.otherAllowance || 0),
      isStatutoryHoliday: !!shift.isStatutoryHoliday,
      segments: shift.segments.map((seg) => ({ ...seg, id: uid(), _touched: true })),
      scheduledMin: shift.scheduledMin, lateNightRate: shift.lateNightRate, overtimeRate: shift.overtimeRate, holidayRate: shift.holidayRate,
    });
    setWarn([]);
    formRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function pickTemplate(t) {
    const d = profileDefaults(t.employer, employerProfiles);
    onAdd({ date: effectiveDate, employer: t.employer, breakMin: t.breakMin, breakStart: t.breakStart || "", breakEnd: t.breakEnd || "", transport: t.transport || 0, otherAllowance: 0, isStatutoryHoliday: false, segments: t.segments, scheduledMin: d.scheduledMin, lateNightRate: d.lateNightRate, overtimeRate: d.overtimeRate, holidayRate: d.holidayRate });
    setJustAdded(t.id);
    setTimeout(() => setJustAdded(null), 900);
  }

  const dayShifts = selectedDate ? monthShifts.filter((s) => s.date === selectedDate) : [];
  const hint = breakHint(preview.totalMin);

  return (
    <>
      <CalendarMonth month={month} monthShifts={monthShifts} employerClassifications={employerClassifications} selectedDate={selectedDate} onSelectDate={setSelectedDate} onAddDate={handleAddDate} />
      <DayDetail date={selectedDate} dayShifts={dayShifts} employerClassifications={employerClassifications} onDelete={onDelete} onAddClick={() => handleAddDate(selectedDate)} onEdit={handleEdit} />

      <TemplateChips templates={templates} onPick={pickTemplate} onDelete={onDeleteTemplate} justAdded={justAdded} />

      <div className="card" ref={formRef} style={{ scrollMarginTop: 84 }}>
        <div className="card-title-row">
          <h3 className="card-title">{editingId ? "シフトを編集" : "シフトを追加"}</h3>
          {editingId && <button className="chip-btn" onClick={resetForm}><X size={13} />編集をやめる</button>}
        </div>

        <div className="target-date-badge">
          <span className="target-date-label">{editingId ? "編集中の日付" : "追加先の日付"}</span>
          <span className="target-date-value">{Number(effectiveDate.slice(5, 7))}月{Number(effectiveDate.slice(8, 10))}日{!selectedDate && <span className="target-date-today"> ・ 本日</span>}</span>
          {!editingId && <span className="target-date-hint">カレンダーの日付をタップすると変更できます</span>}
        </div>

        <div className="form-grid" style={{ marginTop: 12 }}>
          <label className="field">
            <span className="field-label">勤務先</span>
            <input ref={employerInputRef} list="employer-list" value={form.employer} placeholder="例：カフェ○○"
              onChange={(e) => setForm({ ...form, employer: e.target.value })} onBlur={(e) => applyProfile(e.target.value)} />
            <datalist id="employer-list">{employerNames.map((n) => <option value={n} key={n} />)}</datalist>
          </label>
        </div>
        {activeProfile && <p className="profile-hint"><Info size={11} />「{activeProfile.name}」の設定を適用しました（下の詳細設定で今回だけ変更できます）</p>}

        <div className="segments-list">
          {form.segments.map((seg, i) => (
            <div className="segment-row" key={seg.id}>
              <span className="segment-index">{i + 1}</span>
              <input type="time" value={seg.start} onChange={(e) => updateSegment(seg.id, { start: e.target.value })} />
              <span className="segment-sep">〜</span>
              <input type="time" value={seg.end} onChange={(e) => updateSegment(seg.id, { end: e.target.value })} />
              <input type="number" min="0" className="segment-wage" placeholder="時給" value={seg.wage} onChange={(e) => updateSegment(seg.id, { wage: e.target.value })} />
              {form.segments.length > 1 && <button className="segment-del" aria-label="この時間帯を削除" onClick={() => removeSegment(seg.id)}><X size={13} /></button>}
            </div>
          ))}
        </div>
        <button type="button" className="add-segment-btn" onClick={addSegment}><Plus size={13} />時間帯を追加（時給が変わる場合）</button>

        <div className="form-grid" style={{ marginTop: 12 }}>
          <label className="field half"><span className="field-label">休憩の開始(任意)</span><input type="time" value={form.breakStart} onChange={(e) => setForm((f) => applyBreakTimes({ ...f, breakStart: e.target.value }))} /></label>
          <label className="field half"><span className="field-label">休憩の終了(任意)</span><input type="time" value={form.breakEnd} onChange={(e) => setForm((f) => applyBreakTimes({ ...f, breakEnd: e.target.value }))} /></label>
          <label className="field half">
            <span className="field-label">休憩(分){form.breakStart && form.breakEnd ? "・自動計算" : ""}</span>
            <input type="number" min="0" value={form.breakMin} disabled={!!(form.breakStart && form.breakEnd)} onChange={(e) => setForm({ ...form, breakMin: e.target.value })} />
          </label>
          <label className="field half"><span className="field-label">交通費(円)</span><input type="number" min="0" value={form.transport} onChange={(e) => setForm({ ...form, transport: e.target.value })} /></label>
          <label className="field half"><span className="field-label">その他手当(円)</span><input type="number" min="0" value={form.otherAllowance} onChange={(e) => setForm({ ...form, otherAllowance: e.target.value })} /></label>
        </div>
        {Number(form.breakMin) > 0 && (
          form.breakStart && form.breakEnd ? (
            <p className="break-note break-note-ok">✓ 正確な計算：休憩時間（{form.breakStart}〜{form.breakEnd}）を実働時間から除外してから深夜・残業を判定します。</p>
          ) : form.breakStart ? (
            <p className="break-note break-note-ok">✓ 正確な計算：休憩の開始時刻（{form.breakStart}〜）をもとに実働時間から除外します。終了時刻も入れると休憩の分数を自動計算できます。</p>
          ) : (
            <p className="break-note break-note-warn">概算：休憩の開始・終了時刻が未指定のため、休憩時間を勤務全体の平均単価で按分しています。深夜帯や時給が変わる時間帯に休憩がかかる場合、実際の給与とズレる可能性があります。開始・終了時刻を入力すると正確な計算に切り替わります。</p>
          )
        )}
        {hint && <p className="break-hint"><Info size={11} />{hint}</p>}

        <label className="template-save-row" style={{ marginTop: 14 }}>
          <input type="checkbox" checked={form.isStatutoryHoliday} onChange={(e) => setForm({ ...form, isStatutoryHoliday: e.target.checked })} />
          <span>この日は法定休日として計算する（+{Math.round(form.holidayRate * 100)}%）</span>
        </label>

        <button type="button" className="advanced-toggle" onClick={() => setShowAdvanced((v) => !v)}>
          <ChevronDown size={13} style={{ transform: showAdvanced ? "rotate(180deg)" : "none", transition: "transform .15s" }} />
          詳細設定（今回だけ変更）
        </button>
        {showAdvanced && (
          <div className="form-grid" style={{ marginTop: 8 }}>
            <label className="field half"><span className="field-label">所定労働時間(h)</span><input type="number" min="0" step="0.5" value={form.scheduledMin / 60} onChange={(e) => setForm({ ...form, scheduledMin: Math.round(Number(e.target.value || 0) * 60) })} /></label>
            <label className="field half"><span className="field-label">深夜割増率(%)</span><input type="number" min="0" value={Math.round(form.lateNightRate * 100)} onChange={(e) => setForm({ ...form, lateNightRate: Number(e.target.value || 0) / 100 })} /></label>
            <label className="field half"><span className="field-label">残業割増率(%)</span><input type="number" min="0" value={Math.round(form.overtimeRate * 100)} onChange={(e) => setForm({ ...form, overtimeRate: Number(e.target.value || 0) / 100 })} /></label>
            <label className="field half"><span className="field-label">法定休日割増率(%)</span><input type="number" min="0" value={Math.round(form.holidayRate * 100)} onChange={(e) => setForm({ ...form, holidayRate: Number(e.target.value || 0) / 100 })} /></label>
          </div>
        )}

        <div className="preview-card">
          <span className="field-label">今回の給与予測</span>
          <div className="preview-lines">
            <div className="preview-line"><span>基本給</span><span>{yen(preview.base)}</span></div>
            {preview.breakdown.overtimeExtra > 0 && <div className="preview-line"><span>残業割増</span><span>+{yen(preview.breakdown.overtimeExtra)}</span></div>}
            {preview.breakdown.lateNightExtra > 0 && <div className="preview-line"><span>深夜割増</span><span>+{yen(preview.breakdown.lateNightExtra)}</span></div>}
            {preview.breakdown.holidayExtra > 0 && <div className="preview-line"><span>法定休日割増</span><span>+{yen(preview.breakdown.holidayExtra)}</span></div>}
            {Number(form.transport) > 0 && <div className="preview-line"><span>交通費</span><span>+{yen(form.transport)}</span></div>}
            {Number(form.otherAllowance) > 0 && <div className="preview-line"><span>その他手当</span><span>+{yen(form.otherAllowance)}</span></div>}
          </div>
          <div className="preview-top" style={{ marginTop: 8, paddingTop: 8, borderTop: "1px dashed var(--line)" }}>
            <span className="field-label" style={{ fontWeight: 800 }}>合計（{(preview.netMin / 60).toFixed(1)}時間）</span>
            <span className="preview-amount">{yen(preview.netPay)}</span>
          </div>
          <p className="preview-caption">22:00〜5:00は深夜割増として自動計算します。残業は、保存後に同じ勤務先のその日・その週の他のシフトと合算した上で正確に判定されます（このプレビューは単独で見た概算です）。</p>
        </div>
        {anomalies.length > 0 && (
          <div className="anomaly-box">
            {anomalies.map((w, i) => <p key={i} className="anomaly-text"><Info size={11} />{w}</p>)}
          </div>
        )}

        <label className="template-save-row">
          <input type="checkbox" checked={saveAsTemplate} onChange={(e) => setSaveAsTemplate(e.target.checked)} />
          <span>この内容をフォーマットとして保存（固定シフトに便利）</span>
        </label>
        {saveAsTemplate && <input className="template-name-input" placeholder="フォーマット名（例：平日レギュラー）" value={templateName} onChange={(e) => setTemplateName(e.target.value)} />}

        {warn.length > 0 && <div className="warn-box">{warn.map((w, i) => <p key={i} className="form-warn" style={{ margin: i === 0 ? "10px 0 0" : "4px 0 0" }}>・{w}</p>)}</div>}
        <button type="button" className="primary-btn" onClick={submit}><Plus size={17} />{editingId ? "更新する" : "シフトを追加"}</button>
      </div>

      <div className="card">
        <h3 className="card-title">この月のシフト一覧</h3>
        {monthShifts.length === 0 && <p className="empty-note">まだ記録がありません。</p>}
        {monthShifts.map((s) => {
          const { netPay, breakdown, transport: tr, scheduledOtMin, preciseBreak } = payFor(s, employerClassifications);
          const isApprox = Number(s.breakMin) > 0 && !preciseBreak;
          return (
            <div className="entry-card" key={s.id}>
              <div className="entry-accent" style={{ background: s.isStatutoryHoliday ? "#F43F5E" : "#10B981" }} />
              <button className="entry-body entry-body-btn" onClick={() => handleEdit(s)}>
                <div className="entry-top"><span className="entry-name">{s.employer}</span><span className="entry-amount up">{yen(netPay)}</span></div>
                <span className="entry-sub">{s.date.slice(5)} ・ {segmentsSummary(s.segments)}{s.breakMin > 0 ? ` ・ 休${s.breakMin}分` : ""}</span>
                <div className="badge-row">
                  {Number(s.breakMin) > 0 && <span className={"badge precision" + (isApprox ? " approx" : "")}>{isApprox ? "概算" : "正確"}</span>}
                  {scheduledOtMin > 0 && <span className="badge scheduled">所定内残業</span>}
                  {breakdown.lateNightExtra > 0 && <span className="badge">深夜</span>}
                  {breakdown.overtimeExtra > 0 && <span className="badge">法定残業</span>}
                  {breakdown.holidayExtra > 0 && <span className="badge holiday">法定休日</span>}
                  {tr > 0 && <span className="badge transport">交通費</span>}
                </div>
              </button>
              <button className="del-btn" aria-label="削除" onClick={() => onDelete(s.id)}><Trash2 size={14} /></button>
            </div>
          );
        })}
      </div>

      <EmployerProfilesPanel profiles={employerProfiles} onSave={onSaveEmployerProfile} onDelete={onDeleteEmployerProfile} />
    </>
  );
}

const DAY_OPTIONS = [0, ...Array.from({ length: 31 }, (_, i) => i + 1)]; // 0 = 末日

function EmployerProfilesPanel({ profiles, onSave, onDelete }) {
  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing] = useState(null);
  const [name, setName] = useState("");
  const [scheduledHours, setScheduledHours] = useState("8");
  const [defaultWage, setDefaultWage] = useState("");
  const [defaultTransport, setDefaultTransport] = useState("");
  const [otherAllowance, setOtherAllowance] = useState("");
  const [closingDay, setClosingDay] = useState(0);
  const [paydayMonthOffset, setPaydayMonthOffset] = useState(1);
  const [paydayDay, setPaydayDay] = useState(25);
  const [employmentType, setEmploymentType] = useState("アルバイト");
  const [lateNightRate, setLateNightRate] = useState("25");
  const [overtimeRate, setOvertimeRate] = useState("25");
  const [holidayRate, setHolidayRate] = useState("35");
  const [warn, setWarn] = useState("");

  function loadForEdit(p) {
    setEditing(p.name); setName(p.name); setScheduledHours(String(p.scheduledHours));
    setDefaultWage(String(p.defaultWage || "")); setDefaultTransport(String(p.defaultTransport || ""));
    setOtherAllowance(String(p.otherAllowance || ""));
    setClosingDay(p.closingDay != null ? p.closingDay : 0);
    setPaydayMonthOffset(p.paydayMonthOffset != null ? p.paydayMonthOffset : 1);
    setPaydayDay(p.paydayDay != null ? p.paydayDay : 25);
    setEmploymentType(p.employmentType || "アルバイト");
    setLateNightRate(String(Math.round((p.lateNightRate ?? 0.25) * 100)));
    setOvertimeRate(String(Math.round((p.overtimeRate ?? 0.25) * 100)));
    setHolidayRate(String(Math.round((p.holidayRate ?? 0.35) * 100)));
    setShowForm(true);
  }
  function reset() {
    setEditing(null); setName(""); setScheduledHours("8"); setDefaultWage(""); setDefaultTransport("");
    setOtherAllowance(""); setClosingDay(0); setPaydayMonthOffset(1); setPaydayDay(25); setEmploymentType("アルバイト");
    setLateNightRate("25"); setOvertimeRate("25"); setHolidayRate("35"); setWarn("");
  }
  function submit() {
    if (!name) { setWarn("勤務先名を入力してください"); return; }
    setWarn("");
    onSave({ name, scheduledHours: Number(scheduledHours) || 8, defaultWage: Number(defaultWage) || 0, defaultTransport: Number(defaultTransport) || 0, otherAllowance: Number(otherAllowance) || 0, closingDay: Number(closingDay), paydayMonthOffset: Number(paydayMonthOffset), paydayDay: Number(paydayDay), employmentType, lateNightRate: Number(lateNightRate) / 100, overtimeRate: Number(overtimeRate) / 100, holidayRate: Number(holidayRate) / 100 });
    reset();
    setShowForm(false);
  }

  const todayStr = todayYMD();
  const previewPeriod = computePayPeriod(todayStr, Number(closingDay));
  const previewPayday = computePaymentDate(previewPeriod.periodEnd, Number(paydayMonthOffset), Number(paydayDay));

  return (
    <div className="card">
      <div className="card-title-row">
        <h3 className="card-title">勤務先の設定</h3>
        {!showForm && <button className="chip-btn" onClick={() => { reset(); setShowForm(true); }}><Plus size={13} />勤務先を追加</button>}
      </div>
      {!showForm && <p className="pattern-hint" style={{ marginBottom: 12 }}>時給・所定労働時間・割増率などを登録しておくと、シフト追加時に自動で適用されます。行をタップすると編集できます。</p>}

      {profiles.length === 0 && !showForm && <p className="empty-note">まだ登録がありません。</p>}
      {!showForm && profiles.map((p) => {
        const period = computePayPeriod(todayStr, p.closingDay || 0);
        const pd = computePaymentDate(period.periodEnd, p.paydayMonthOffset != null ? p.paydayMonthOffset : 1, p.paydayDay != null ? p.paydayDay : 25);
        return (
          <div className="list-row" key={p.id}>
            <button className="profile-row-btn" onClick={() => loadForEdit(p)}>
              <span className="list-row-label" style={{ color: "var(--ink)", fontWeight: 700 }}>{p.name}</span>
              <div className="entry-sub">{p.employmentType} ・ 所定{p.scheduledHours}h ・ 深夜{Math.round(p.lateNightRate * 100)}% ・ 残業{Math.round(p.overtimeRate * 100)}% ・ 休日{Math.round(p.holidayRate * 100)}%</div>
              <div className="entry-sub">締め{p.closingDay === 0 ? "末日" : p.closingDay + "日"} ・ 今の期間({formatPeriodDate(period.periodStart)}〜{formatPeriodDate(period.periodEnd)})分は{formatFullDate(pd)}払い予定</div>
            </button>
            <button className="del-btn" aria-label="削除" onClick={() => onDelete(p.id)}><Trash2 size={14} /></button>
          </div>
        );
      })}

      {showForm && (
        <>
          <p className="pattern-hint" style={{ marginBottom: 12 }}>時給・所定労働時間・割増率・交通費などを勤務先ごとに登録しておくと、シフト追加時にその内容が自動で適用されます（あとから変更しても、過去に追加済みのシフトには影響しません）。</p>
          <div className="form-grid">
            <label className="field half"><span className="field-label">勤務先名</span><input value={name} placeholder="例：カフェ○○" onChange={(e) => setName(e.target.value)} disabled={!!editing} /></label>
            <label className="field half"><span className="field-label">雇用形態</span><select value={employmentType} onChange={(e) => setEmploymentType(e.target.value)}>{EMPLOYMENT_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}</select></label>
            <label className="field half"><span className="field-label">所定労働時間(時間/日)</span><input type="number" min="0" step="0.5" value={scheduledHours} onChange={(e) => setScheduledHours(e.target.value)} /></label>
            <label className="field half"><span className="field-label">時給の初期値(円)</span><input type="number" min="0" value={defaultWage} onChange={(e) => setDefaultWage(e.target.value)} /></label>
            <label className="field half"><span className="field-label">交通費の初期値(円)</span><input type="number" min="0" value={defaultTransport} onChange={(e) => setDefaultTransport(e.target.value)} /></label>
            <label className="field half"><span className="field-label">その他手当の初期値(円)</span><input type="number" min="0" value={otherAllowance} onChange={(e) => setOtherAllowance(e.target.value)} /></label>
            <label className="field half">
              <span className="field-label">締め日</span>
              <select value={closingDay} onChange={(e) => setClosingDay(Number(e.target.value))}>
                {DAY_OPTIONS.map((d) => <option key={d} value={d}>{d === 0 ? "末日" : d + "日"}</option>)}
              </select>
            </label>
            <label className="field half">
              <span className="field-label">支給タイミング</span>
              <select value={paydayMonthOffset} onChange={(e) => setPaydayMonthOffset(Number(e.target.value))}>
                <option value={0}>締め月と同じ月</option>
                <option value={1}>翌月</option>
                <option value={2}>翌々月</option>
              </select>
            </label>
            <label className="field half">
              <span className="field-label">支給日</span>
              <select value={paydayDay} onChange={(e) => setPaydayDay(Number(e.target.value))}>
                {DAY_OPTIONS.map((d) => <option key={d} value={d}>{d === 0 ? "末日" : d + "日"}</option>)}
              </select>
            </label>
            <label className="field half"><span className="field-label">深夜割増率(%)</span><input type="number" min="0" value={lateNightRate} onChange={(e) => setLateNightRate(e.target.value)} /></label>
            <label className="field half"><span className="field-label">残業割増率(%)</span><input type="number" min="0" value={overtimeRate} onChange={(e) => setOvertimeRate(e.target.value)} /></label>
            <label className="field half"><span className="field-label">法定休日割増率(%)</span><input type="number" min="0" value={holidayRate} onChange={(e) => setHolidayRate(e.target.value)} /></label>
          </div>
          <p className="profile-hint" style={{ marginTop: 4 }}><Info size={11} />例：本日（{formatPeriodDate(todayStr)}）の勤務は{formatPeriodDate(previewPeriod.periodStart)}〜{formatPeriodDate(previewPeriod.periodEnd)}の期間分として、{formatFullDate(previewPayday)}に支給される想定です。</p>
          {warn && <p className="form-warn">{warn}</p>}
          <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
            <button type="button" className="primary-btn expense" onClick={submit} style={{ marginTop: 12 }}><Plus size={17} />{editing ? "更新する" : "勤務先を保存"}</button>
            <button type="button" className="chip-btn" style={{ marginTop: 12 }} onClick={() => { reset(); setShowForm(false); }}>キャンセル</button>
          </div>
        </>
      )}
    </div>
  );
}


function AccordionRow({ label, amount, hoursMin, items, tone }) {
  const [open, setOpen] = useState(false);
  if (amount === 0 && items.length === 0) {
    return <div className="list-row"><span className="list-row-label">{label}</span><span className="list-row-value">{yen(amount)}</span></div>;
  }
  return (
    <div className="accordion-item">
      <button className="accordion-head" onClick={() => setOpen((o) => !o)}>
        <span className="list-row-label">{label}{hoursMin != null && hoursMin > 0 ? `（${hrs(hoursMin)}）` : ""}</span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
          <span className={"list-row-value" + (tone ? " " + tone : "")}>{yen(amount)}</span>
          <ChevronDown size={14} style={{ transform: open ? "rotate(180deg)" : "none", transition: "transform .15s" }} />
        </span>
      </button>
      {open && (
        <div className="accordion-body">
          {items.length === 0 && <p className="empty-note">対象のシフトはありません。</p>}
          {items.map((it, i) => (
            <div className="accordion-line-group" key={i}>
              <div className="accordion-line accordion-line-head">
                <span>{it.shift.date.slice(5)} ・ {it.shift.employer}</span>
                <span>{it.min != null ? `${hrs(it.min)} × ` : ""}{yen(it.amount)}</span>
              </div>
              {it.formula && it.formula.map((f, j) => (
                <div className="formula-line" key={j}>{f.range}（{f.hours.toFixed(1)}h）× ¥{f.wage} × {(f.rate * 100).toFixed(0)}% = {yen(f.amount)}</div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function FlowSummary({ gross, deductions, net }) {
  return (
    <div className="flow-card">
      <div className="flow-box"><span className="flow-label">総支給</span><span className="flow-amount up">{yen(gross)}</span></div>
      <ArrowRight size={16} className="flow-arrow" />
      <div className="flow-box"><span className="flow-label">控除</span><span className="flow-amount down">−{yen(deductions)}</span></div>
      <ArrowRight size={16} className="flow-arrow" />
      <div className="flow-box highlight"><span className="flow-label">手取り</span><span className="flow-amount">{yen(net)}</span></div>
    </div>
  );
}

function PayslipCard({ payslip, hasApproximateBreak }) {
  return (
    <div className="card">
      <h3 className="card-title">給与明細（支給）</h3>
      <p className="pattern-hint" style={{ marginBottom: 10 }}>各項目をタップすると、対象のシフトと時間・金額の内訳を確認できます。</p>

      <div className="hours-summary">
        <div className="hours-row"><span>通常労働</span><span>{hrs(payslip.normalMin)}</span></div>
        {payslip.scheduledOtMin > 0 && <div className="hours-row"><span>所定内残業（割増なし）</span><span>{hrs(payslip.scheduledOtMin)}</span></div>}
        {payslip.overtimeMin > 0 && <div className="hours-row accent"><span>法定時間外労働</span><span>{hrs(payslip.overtimeMin)}</span></div>}
        {payslip.lateNightMin > 0 && <div className="hours-row accent"><span>深夜労働</span><span>{hrs(payslip.lateNightMin)}</span></div>}
        {payslip.holidayMin > 0 && <div className="hours-row accent"><span>法定休日労働</span><span>{hrs(payslip.holidayMin)}</span></div>}
      </div>
      {hasApproximateBreak && (
        <p className="approx-note"><Info size={11} />概算：休憩の開始・終了時刻が未入力のシフトが含まれています。その分の内訳は平均単価による按分計算です。</p>
      )}

      <AccordionRow label="基本給" amount={payslip.base} hoursMin={payslip.baseMin} items={[]} />
      <AccordionRow label="法定時間外(残業)割増" amount={payslip.overtime} hoursMin={payslip.overtimeMin} items={payslip.contributors.overtime} tone="up" />
      <AccordionRow label="深夜割増" amount={payslip.lateNight} hoursMin={payslip.lateNightMin} items={payslip.contributors.lateNight} tone="up" />
      <AccordionRow label="法定休日割増" amount={payslip.holiday} hoursMin={payslip.holidayMin} items={payslip.contributors.holiday} tone="down" />
      <AccordionRow label="交通費" amount={payslip.transport} items={payslip.contributors.transport} tone="up" />
      <AccordionRow label="その他手当" amount={payslip.otherAllowance} items={payslip.contributors.otherAllowance} tone="up" />
      <div className="list-row total-row"><span className="list-row-label" style={{ fontWeight: 800, color: "var(--ink)" }}>総支給額</span><span className="list-row-value up strong">{yen(payslip.grossTotal)}</span></div>
    </div>
  );
}

function WeeklyHoursCard({ weeklyBuckets, weeklyThresholdHours, onSetWeeklyThresholdHours }) {
  const [openWeek, setOpenWeek] = useState(null);
  const [thresholdInput, setThresholdInput] = useState(String(weeklyThresholdHours));
  const threshold = weeklyThresholdHours * 60;
  return (
    <div className="card">
      <h3 className="card-title">週ごとの労働時間</h3>
      <p className="pattern-hint" style={{ marginBottom: 10 }}>
        週40時間（法定）を超えた分は、勤務先ごとに集計して自動的に法定時間外として給与に反映されています。以下の「基準時間」は、会社の規定などと見比べるための参考値で、40時間という法定ラインそのものは変更されません。
      </p>
      <div className="threshold-row">
        <span className="field-label">見比べ用の基準時間(h・参考)</span>
        <input type="number" min="0" value={thresholdInput} onChange={(e) => setThresholdInput(e.target.value)}
          onBlur={() => onSetWeeklyThresholdHours(Number(thresholdInput) || 40)} className="threshold-input" />
      </div>
      {weeklyBuckets.length === 0 && <p className="empty-note">この月のシフト記録がありません。</p>}
      {weeklyBuckets.map(([wk, v]) => {
        const min = v.totalMin;
        const over = min > threshold;
        const open = openWeek === wk;
        return (
          <div className="accordion-item" key={wk}>
            <button className="accordion-head" onClick={() => setOpenWeek(open ? null : wk)}>
              <span className="list-row-label">{weekLabel(wk)}</span>
              <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
                <span className={"list-row-value" + (v.weeklyLegalOtMin > 0 ? " down" : "")}>{hrs(min)}{v.weeklyLegalOtMin > 0 ? `（うち週次残業${hrs(v.weeklyLegalOtMin)}）` : ""}</span>
                <ChevronDown size={14} style={{ transform: open ? "rotate(180deg)" : "none", transition: "transform .15s" }} />
              </span>
            </button>
            {open && (
              <div className="accordion-body">
                <div className="accordion-line">
                  <span>{over ? `見比べ用基準(${weeklyThresholdHours}h)からの超過` : `見比べ用基準(${weeklyThresholdHours}h)までの残り`}</span>
                  <span>{over ? `${((min - threshold) / 60).toFixed(1)}h超過` : `残り${((threshold - min) / 60).toFixed(1)}h`}</span>
                </div>
                {v.weeklyLegalOtMin > 0 && (
                  <div className="accordion-line">
                    <span>法定40時間を超えて給与に反映された時間</span>
                    <span>{hrs(v.weeklyLegalOtMin)}</span>
                  </div>
                )}
                {v.items.map((it, i) => <div className="accordion-line" key={i}><span>{it.shift.date.slice(5)} ・ {it.shift.employer}</span><span>{hrs(it.min)}</span></div>)}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function CompareRow({ label, appValue, actualValue, onChangeActual, formatFn, unit }) {
  const hasActual = actualValue !== "" && actualValue != null;
  const diff = hasActual ? Number(actualValue) - appValue : null;
  return (
    <div className="compare-row">
      <span className="compare-label">{label}</span>
      <span className="compare-app">{formatFn(appValue)}</span>
      <input className="compare-input" type="number" placeholder="実際" value={actualValue} onChange={(e) => onChangeActual(e.target.value)} />
      <span className={"compare-diff" + (diff == null ? "" : diff === 0 ? "" : diff > 0 ? " up" : " down")}>
        {diff == null ? "―" : diff === 0 ? "一致" : `${diff > 0 ? "+" : "−"}${formatFn(Math.abs(diff)).replace(/^0$/, "0")}`}
      </span>
    </div>
  );
}

function ForecastCard({ payslip, monthIncome, deductionsTotal, netIncome, actualPay, onSetActualPay }) {
  const savedHours = (actualPay && actualPay.hours) || {};
  const savedAmounts = (actualPay && actualPay.amounts) || {};
  const [hours, setHours] = useState({
    normal: savedHours.normal ?? "", overtime: savedHours.overtime ?? "", lateNight: savedHours.lateNight ?? "", holiday: savedHours.holiday ?? "",
  });
  const [amounts, setAmounts] = useState({
    base: savedAmounts.base ?? "", overtime: savedAmounts.overtime ?? "", lateNight: savedAmounts.lateNight ?? "", holiday: savedAmounts.holiday ?? "",
    transport: savedAmounts.transport ?? "", otherAllowance: savedAmounts.otherAllowance ?? "",
    gross: savedAmounts.gross ?? "", deductions: savedAmounts.deductions ?? "", net: savedAmounts.net ?? "",
  });
  const [reasons, setReasons] = useState((actualPay && actualPay.reasons) || []);
  const [note, setNote] = useState((actualPay && actualPay.note) || "");

  function toggleReason(r) {
    setReasons((rs) => (rs.includes(r) ? rs.filter((x) => x !== r) : [...rs, r]));
  }
  function save() {
    onSetActualPay({ hours, amounts, reasons, note });
  }

  const yenFmt = (n) => yen(n);
  const hFmt = (n) => hrs(Math.round(n * 60));

  const grossDiff = amounts.gross !== "" ? Number(amounts.gross) - monthIncome : null;
  const netDiff = amounts.net !== "" ? Number(amounts.net) - netIncome : null;

  return (
    <div className="card">
      <h3 className="card-title">実際の給与明細と照合</h3>
      <p className="pattern-hint" style={{ marginBottom: 10 }}>給与明細が届いたら、項目ごとに実際の数字を入力してください。アプリの計算とズレている項目がひと目でわかります。</p>

      <p className="compare-section-title">労働時間</p>
      <div className="compare-header"><span></span><span>アプリ</span><span>実際</span><span>差</span></div>
      <CompareRow label="通常労働" appValue={payslip.normalMin / 60} actualValue={hours.normal} onChangeActual={(v) => setHours({ ...hours, normal: v })} formatFn={hFmt} />
      <CompareRow label="時間外労働" appValue={payslip.overtimeMin / 60} actualValue={hours.overtime} onChangeActual={(v) => setHours({ ...hours, overtime: v })} formatFn={hFmt} />
      <CompareRow label="深夜労働" appValue={payslip.lateNightMin / 60} actualValue={hours.lateNight} onChangeActual={(v) => setHours({ ...hours, lateNight: v })} formatFn={hFmt} />
      <CompareRow label="休日労働" appValue={payslip.holidayMin / 60} actualValue={hours.holiday} onChangeActual={(v) => setHours({ ...hours, holiday: v })} formatFn={hFmt} />

      <p className="compare-section-title" style={{ marginTop: 14 }}>支給額</p>
      <div className="compare-header"><span></span><span>アプリ</span><span>実際</span><span>差</span></div>
      <CompareRow label="基本給" appValue={payslip.base} actualValue={amounts.base} onChangeActual={(v) => setAmounts({ ...amounts, base: v })} formatFn={yenFmt} />
      <CompareRow label="時間外手当" appValue={payslip.overtime} actualValue={amounts.overtime} onChangeActual={(v) => setAmounts({ ...amounts, overtime: v })} formatFn={yenFmt} />
      <CompareRow label="深夜手当" appValue={payslip.lateNight} actualValue={amounts.lateNight} onChangeActual={(v) => setAmounts({ ...amounts, lateNight: v })} formatFn={yenFmt} />
      <CompareRow label="休日手当" appValue={payslip.holiday} actualValue={amounts.holiday} onChangeActual={(v) => setAmounts({ ...amounts, holiday: v })} formatFn={yenFmt} />
      <CompareRow label="交通費" appValue={payslip.transport} actualValue={amounts.transport} onChangeActual={(v) => setAmounts({ ...amounts, transport: v })} formatFn={yenFmt} />
      <CompareRow label="その他手当" appValue={payslip.otherAllowance} actualValue={amounts.otherAllowance} onChangeActual={(v) => setAmounts({ ...amounts, otherAllowance: v })} formatFn={yenFmt} />
      <CompareRow label="総支給額" appValue={monthIncome} actualValue={amounts.gross} onChangeActual={(v) => setAmounts({ ...amounts, gross: v })} formatFn={yenFmt} />
      <CompareRow label="控除" appValue={deductionsTotal} actualValue={amounts.deductions} onChangeActual={(v) => setAmounts({ ...amounts, deductions: v })} formatFn={yenFmt} />
      <CompareRow label="差引支給額" appValue={netIncome} actualValue={amounts.net} onChangeActual={(v) => setAmounts({ ...amounts, net: v })} formatFn={yenFmt} />

      {(grossDiff != null && grossDiff !== 0) || (netDiff != null && netDiff !== 0) ? (
        <p className="compare-hint-warn"><Info size={11} />差がある項目が見つかりました。上の表でどこがズレているか確認してみてください。深夜・残業の時間そのものがズレている場合はシフトの入力内容を、金額だけズレている場合は割増率や控除の設定を見直すと原因がわかりやすくなります。</p>
      ) : (grossDiff === 0 && netDiff === 0) ? (
        <p className="compare-hint-ok">✓ 総支給額・差引支給額とも一致しています。</p>
      ) : null}

      <p className="field-label" style={{ marginTop: 12, marginBottom: 6 }}>差が出た理由（考えられるものを選択）</p>
      <div className="reason-chips">
        {DIFF_REASONS.map((r) => (
          <button key={r} type="button" className={"reason-chip" + (reasons.includes(r) ? " active" : "")} onClick={() => toggleReason(r)}>{r}</button>
        ))}
      </div>
      <input className="template-name-input" style={{ marginTop: 10 }} placeholder="メモ（任意）" value={note} onChange={(e) => setNote(e.target.value)} />
      <button type="button" className="data-btn" style={{ marginTop: 10 }} onClick={save}>記録する</button>
    </div>
  );
}

const AUTO_RATES = [
  { label: "健康保険料", rate: 0.049, note: "協会けんぽ目安・都道府県により変動" },
  { label: "厚生年金保険料", rate: 0.0915, note: "全国一律" },
  { label: "雇用保険料", rate: 0.006, note: "一般の事業の目安" },
];

function PaydayCard({ employerProfiles }) {
  if (employerProfiles.length === 0) return null;
  const todayStr = todayYMD();
  return (
    <div className="card">
      <h3 className="card-title">給与の支給予定</h3>
      <p className="pattern-hint" style={{ marginBottom: 10 }}>勤務した月と、実際に給与が振り込まれる月は締め日によってズレることがあります。勤務先ごとの締め日・支給日をもとに、直近の支給予定を確認できます。</p>
      {employerProfiles.map((p) => {
        const period = computePayPeriod(todayStr, p.closingDay || 0);
        const pd = computePaymentDate(period.periodEnd, p.paydayMonthOffset != null ? p.paydayMonthOffset : 1, p.paydayDay != null ? p.paydayDay : 25);
        return (
          <div className="list-row" key={p.id}>
            <div>
              <span className="list-row-label" style={{ color: "var(--ink)", fontWeight: 700 }}>{p.name}</span>
              <div className="entry-sub">{formatPeriodDate(period.periodStart)}〜{formatPeriodDate(period.periodEnd)}分</div>
            </div>
            <span className="list-row-value">{formatFullDate(pd)}</span>
          </div>
        );
      })}
    </div>
  );
}

function WageTab({ month, payslip, weeklyBuckets, monthDeductions, deductionsTotal, monthIncome, netIncome, hasApproximateBreak, employerProfiles, actualPay, onSetActualPay, onAddDeduction, onDeleteDeduction, weeklyThresholdHours, onSetWeeklyThresholdHours }) {
  const [showDeductionForm, setShowDeductionForm] = useState(false);
  const [category, setCategory] = useState(DEDUCTION_CATEGORIES[0]);
  const [note, setNote] = useState("");
  const [amount, setAmount] = useState("");
  const [warn, setWarn] = useState("");
  const [justAuto, setJustAuto] = useState(null);

  function submit() {
    if (!amount) { setWarn("金額を入力してください"); return; }
    setWarn("");
    onAddDeduction({ category, note, amount });
    setNote(""); setAmount(""); setShowDeductionForm(false);
  }
  function addAuto(preset) {
    const amt = Math.round((monthIncome * preset.rate) / 10) * 10;
    onAddDeduction({ category: preset.label, note: `概算 ${(preset.rate * 100).toFixed(2)}%`, amount: amt });
    setJustAuto(preset.label);
    setTimeout(() => setJustAuto(null), 900);
  }

  return (
    <>
      <FlowSummary gross={monthIncome} deductions={deductionsTotal} net={netIncome} />
      <PayslipCard payslip={payslip} hasApproximateBreak={hasApproximateBreak} />
      <WeeklyHoursCard weeklyBuckets={weeklyBuckets} weeklyThresholdHours={weeklyThresholdHours} onSetWeeklyThresholdHours={onSetWeeklyThresholdHours} />
      <PaydayCard employerProfiles={employerProfiles} />

      <div className="card">
        <div className="card-title-row">
          <h3 className="card-title">控除（概算・参考値）</h3>
          {!showDeductionForm && <button className="chip-btn" onClick={() => setShowDeductionForm(true)}><Plus size={13} />手入力で追加</button>}
        </div>
        <p className="pattern-hint" style={{ marginBottom: 12 }}>健康保険・厚生年金・雇用保険・所得税・住民税はそれぞれ独立した項目として管理します。条件によって金額が変わるため、ここでの数字はあくまで概算です。実際の給与明細を優先してください。</p>

        <div className="auto-rate-row">
          {AUTO_RATES.map((preset) => (
            <button key={preset.label} className={"auto-rate-chip" + (justAuto === preset.label ? " just-added" : "")} onClick={() => addAuto(preset)} title={preset.note}>
              <span>{preset.label}</span>
              <span className="auto-rate-value">{yen(Math.round((monthIncome * preset.rate) / 10) * 10)}</span>
              <span className="auto-rate-note">概算 {(preset.rate * 100).toFixed(2)}%</span>
            </button>
          ))}
        </div>
        <p className="auto-rate-caption">社会保険料率は将来変わる可能性があるため、正確な金額は必ず給与明細でご確認ください。所得税・住民税は個人差が大きいため自動計算していません。同じカテゴリで再度入力すると、その月の金額が上書きされます（その他控除は複数登録できます）。</p>

        {monthDeductions.length === 0 && <p className="empty-note">この月の控除はまだありません。</p>}
        {monthDeductions.map((d) => (
          <div className="list-row" key={d.id}>
            <div>
              <span className="list-row-label" style={{ color: "var(--ink)", fontWeight: 700 }}>{d.category}</span>
              {d.note && <div className="entry-sub">{d.note}</div>}
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}><span className="list-row-value down">−{yen(d.amount)}</span><button className="del-btn" aria-label="削除" onClick={() => onDeleteDeduction(d.id)}><Trash2 size={14} /></button></div>
          </div>
        ))}

        {showDeductionForm && (
          <>
            <div className="form-grid" style={{ marginTop: 14 }}>
              <label className="field half">
                <span className="field-label">カテゴリ</span>
                <select value={category} onChange={(e) => setCategory(e.target.value)}>
                  {DEDUCTION_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                </select>
              </label>
              <label className="field half"><span className="field-label">金額(円)</span><input type="number" min="0" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
              <label className="field"><span className="field-label">メモ(任意)</span><input value={note} placeholder="例：6月分" onChange={(e) => setNote(e.target.value)} /></label>
            </div>
            {warn && <p className="form-warn">{warn}</p>}
            <div style={{ display: "flex", gap: 8 }}>
              <button type="button" className="primary-btn expense" onClick={submit} style={{ flex: 1 }}><Plus size={17} />控除を追加</button>
              <button type="button" className="chip-btn" style={{ marginTop: 16 }} onClick={() => { setShowDeductionForm(false); setWarn(""); }}>キャンセル</button>
            </div>
          </>
        )}

        <div className="list-row total-row" style={{ marginTop: 16 }}><span className="list-row-label">控除合計</span><span className="list-row-value down">−{yen(deductionsTotal)}</span></div>
        <div className="list-row"><span className="list-row-label" style={{ fontWeight: 800, color: "var(--ink)" }}>手取り予測</span><span className="list-row-value up strong">{yen(netIncome)}</span></div>
      </div>

      <ForecastCard payslip={payslip} monthIncome={monthIncome} deductionsTotal={deductionsTotal} netIncome={netIncome} actualPay={actualPay} onSetActualPay={onSetActualPay} />
    </>
  );
}

function ExpensesPanel({ monthExpenses, onAdd, onDelete }) {
  const [form, setForm] = useState({ date: todayYMD(), category: CATEGORIES[0], amount: "", memo: "" });
  const [warn, setWarn] = useState("");

  function submit() {
    if (!form.date || !form.amount) { setWarn("日付と金額を入力してください"); return; }
    setWarn("");
    onAdd(form);
    setForm({ ...form, amount: "", memo: "" });
  }

  return (
    <>
      <div className="card">
        <h3 className="card-title">支出を追加</h3>
        <div className="form-grid">
          <label className="field"><span className="field-label">日付</span><input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></label>
          <label className="field"><span className="field-label">カテゴリ</span><select value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })}>{CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}</select></label>
          <label className="field half"><span className="field-label">金額(円)</span><input type="number" min="0" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} /></label>
          <label className="field half"><span className="field-label">メモ</span><input type="text" value={form.memo} placeholder="任意" onChange={(e) => setForm({ ...form, memo: e.target.value })} /></label>
        </div>
        {warn && <p className="form-warn">{warn}</p>}
        <button type="button" className="primary-btn expense" onClick={submit}><Plus size={17} />支出を追加</button>
      </div>

      <div className="card">
        <h3 className="card-title">この月の支出</h3>
        {monthExpenses.length === 0 && <p className="empty-note">まだ記録がありません。</p>}
        {monthExpenses.map((e) => (
          <div className="entry-card" key={e.id}>
            <div className="entry-accent" style={{ background: CAT_COLORS[e.category] || "#999" }} />
            <div className="entry-body">
              <div className="entry-top"><span className="entry-name">{e.category}</span><span className="entry-amount down">−{yen(e.amount)}</span></div>
              <span className="entry-sub">{e.date.slice(5)}{e.memo ? " ・ " + e.memo : ""}</span>
            </div>
            <button className="del-btn" aria-label="削除" onClick={() => onDelete(e.id)}><Trash2 size={14} /></button>
          </div>
        ))}
      </div>
    </>
  );
}

const STYLE = `
@import url('https://fonts.googleapis.com/css2?family=Zen+Kaku+Gothic+New:wght@400;500;700;900&display=swap');

.app-shell {
  --bg: #F3F4F8; --card: #FFFFFF; --ink: #1D1B2E; --ink-soft: #7A7E93; --line: #ECEDF3;
  --grad-a: #6D5DF6; --grad-b: #9B5DF6; --up: #10B981; --down: #F43F5E;
  font-family: 'Zen Kaku Gothic New', sans-serif; background: var(--bg); color: var(--ink);
  min-height: 100vh; width: 100%; max-width: 420px; margin: 0 auto; position: relative; font-size: 15px;
  transition: background 0.2s, color 0.2s;
}
.app-shell.dark {
  --bg: #131320; --card: #1E1E30; --ink: #EDEBFA; --ink-soft: #9793B3; --line: #34324A;
}
.app-shell.dark .month-nav, .app-shell.dark .theme-toggle, .app-shell.dark .bottom-nav { box-shadow: 0 1px 3px rgba(0,0,0,0.4); }
.app-shell * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
.app-shell button { touch-action: manipulation; font-family: 'Zen Kaku Gothic New', sans-serif; }
.loading { padding: 60px 20px; text-align: center; color: var(--ink-soft); }

.app-header { position: sticky; top: 0; z-index: 5; display: flex; align-items: center; justify-content: space-between; padding: 16px 16px 12px; background: var(--bg); }
.header-actions { display: flex; align-items: center; gap: 8px; }
.theme-toggle { border: none; background: var(--card); color: var(--ink); border-radius: 999px; width: 34px; height: 34px; display: flex; align-items: center; justify-content: center; cursor: pointer; box-shadow: 0 1px 3px rgba(29,27,46,0.06); flex-shrink: 0; }
.theme-toggle:active { background: var(--bg); }
.app-title { font-size: 16px; font-weight: 900; letter-spacing: -0.01em; }
.month-nav { display: flex; align-items: center; gap: 4px; background: var(--card); border-radius: 999px; padding: 4px; box-shadow: 0 1px 3px rgba(29,27,46,0.06); }
.month-nav button { border: none; background: transparent; border-radius: 999px; width: 30px; height: 30px; color: var(--ink); cursor: pointer; display: flex; align-items: center; justify-content: center; }
.month-nav button:active { background: var(--bg); }
.month-label { font-size: 13px; font-weight: 700; padding: 0 6px; min-width: 78px; text-align: center; }

.content { padding: 4px 16px 100px; display: flex; flex-direction: column; gap: 16px; }
.error-banner { background: #FEE2E6; color: var(--down); padding: 10px 14px; border-radius: 14px; font-size: 13px; }
.anomaly-banner { display: flex; align-items: flex-start; gap: 8px; background: #FFFBEB; color: #B45309; padding: 12px 14px; border-radius: 16px; font-size: 12px; line-height: 1.5; font-weight: 600; }
.anomaly-banner svg { flex-shrink: 0; margin-top: 1px; }

.hero-card { background: linear-gradient(135deg, var(--grad-a), var(--grad-b)); border-radius: 28px; padding: 24px 22px; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 10px; color: white; box-shadow: 0 12px 24px -8px rgba(109,93,246,0.45); }
.hero-label { font-size: 12px; font-weight: 700; opacity: 0.85; }
.hero-amount { font-size: 34px; font-weight: 900; letter-spacing: -0.02em; }
.hero-chips { display: flex; gap: 8px; margin-top: 4px; }
.hero-chip { display: flex; align-items: center; gap: 4px; background: rgba(255,255,255,0.18); border-radius: 999px; padding: 6px 11px; font-size: 12px; font-weight: 700; }
.hero-chip.down { background: rgba(0,0,0,0.15); }
.hero-note { font-size: 10.5px; opacity: 0.8; margin-top: 2px; }

.card { background: var(--card); border-radius: 22px; padding: 18px; box-shadow: 0 1px 3px rgba(29,27,46,0.05); }
.card-title { font-size: 14px; font-weight: 800; margin: 0 0 12px; }
.card-title-row { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
.card-title-row .card-title { margin: 0; }
.empty-card { background: var(--card); border-radius: 22px; padding: 24px 18px; text-align: center; color: var(--ink-soft); font-size: 13px; }
.empty-note { color: var(--ink-soft); font-size: 13px; padding: 4px 0; }

.list-row { display: flex; align-items: center; justify-content: space-between; padding: 9px 0; border-bottom: 1px solid var(--line); gap: 8px; }
.list-row:last-child { border-bottom: none; }
.list-row-label { font-size: 13px; color: var(--ink-soft); }
.list-row-value { font-size: 14px; font-weight: 700; }
.list-row-value.up { color: var(--up); }
.list-row-value.down { color: var(--down); }
.list-row-value.strong { font-size: 16px; }
.total-row { margin-top: 2px; padding-top: 12px; border-top: 1px dashed var(--line); }

.bar-row { padding: 8px 0; }
.bar-row-top { display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px; }
.bar-name { display: flex; align-items: center; gap: 7px; font-size: 13px; }
.bar-amount { font-size: 13px; font-weight: 700; }
.cat-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
.bar-track { height: 6px; background: var(--bg); border-radius: 999px; overflow: hidden; }
.bar-fill { height: 100%; border-radius: 999px; }

.calendar-card { background: var(--card); border-radius: 22px; padding: 16px; box-shadow: 0 1px 3px rgba(29,27,46,0.05); }
.calendar-weekdays { display: grid; grid-template-columns: repeat(7, 1fr); margin-bottom: 6px; }
.weekday { text-align: center; font-size: 11px; padding: 4px 0; color: var(--ink-soft); font-weight: 700; }
.weekday.sun { color: var(--down); }
.weekday.sat { color: #3B82F6; }
.calendar-grid { display: grid; grid-template-columns: repeat(7, 1fr); row-gap: 2px; }
.cal-cell { aspect-ratio: 1; min-height: 50px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; border: none; background: transparent; cursor: pointer; border-radius: 14px; padding: 2px; overflow: hidden; }
.cal-cell.empty { cursor: default; }
.cal-day { font-size: 13px; font-weight: 600; color: var(--ink); width: 26px; height: 26px; display: flex; align-items: center; justify-content: center; border-radius: 999px; flex-shrink: 0; }
.cal-day.sun { color: var(--down); }
.cal-day.sat { color: #3B82F6; }
.cal-emp { font-size: 8.5px; font-weight: 700; color: var(--up); max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; padding: 0 2px; }
.cal-cell.has-shift .cal-day { background: #ECFDF5; }
.cal-cell.selected .cal-day { background: linear-gradient(135deg, var(--grad-a), var(--grad-b)); color: white; }
.cal-cell.selected .cal-emp { color: var(--grad-a); font-weight: 800; }
.calendar-hint { text-align: center; font-size: 10.5px; color: var(--ink-soft); margin: 10px 0 0; }

.chip-btn { display: flex; align-items: center; gap: 3px; border: none; background: var(--bg); color: var(--grad-a); border-radius: 999px; padding: 7px 12px; font-size: 12px; font-weight: 700; cursor: pointer; }
.chip-btn:active { background: #E7E4FE; }

.pattern-card { padding-bottom: 14px; }
.pattern-hint { font-size: 11.5px; color: var(--ink-soft); margin: -6px 0 12px; line-height: 1.5; }
.pattern-scroll { display: flex; gap: 8px; overflow-x: auto; padding-bottom: 2px; margin: 0 -18px; padding-left: 18px; padding-right: 18px; }
.pattern-scroll::-webkit-scrollbar { display: none; }
.pattern-employer { font-size: 13px; font-weight: 800; color: var(--ink); }
.pattern-sub { font-size: 10.5px; color: var(--ink-soft); font-weight: 600; }
.pattern-time { font-size: 11px; color: var(--ink-soft); font-weight: 600; }
.pattern-time.break { color: #B8862B; }

.template-chip { position: relative; flex-shrink: 0; min-width: 148px; }
.template-del { position: absolute; top: -6px; right: -6px; width: 20px; height: 20px; border-radius: 50%; border: 2px solid var(--card); background: #D1D5E0; color: white; display: flex; align-items: center; justify-content: center; cursor: pointer; z-index: 2; }
.template-del:active { background: var(--down); }
.template-main { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; border: none; background: var(--bg); border-radius: 16px; padding: 10px 14px; cursor: pointer; width: 100%; transition: background 0.15s, transform 0.15s; }
.template-main:active { transform: scale(0.97); }
.template-chip.just-added .template-main { background: #ECFDF5; }

.target-date-badge { display: flex; flex-direction: column; gap: 2px; background: linear-gradient(135deg, #F0ECFF, #FBEAFB); border-radius: 14px; padding: 10px 14px; }
.target-date-label { font-size: 10.5px; color: var(--grad-a); font-weight: 700; }
.target-date-value { font-size: 16px; font-weight: 900; color: var(--ink); }
.target-date-today { font-size: 12px; font-weight: 700; color: var(--grad-a); }
.target-date-hint { font-size: 10px; color: var(--ink-soft); margin-top: 2px; }

.form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 4px; }
.field { display: flex; flex-direction: column; gap: 5px; grid-column: span 2; min-width: 0; }
.field.half { grid-column: span 1; }
.field-label { font-size: 11.5px; color: var(--ink-soft); font-weight: 700; padding-left: 2px; }
.field input, .field select { font-family: 'Zen Kaku Gothic New', sans-serif; font-size: 15px; padding: 11px 12px; border: none; border-radius: 14px; background: var(--bg); color: var(--ink); width: 100%; min-width: 0; min-height: 44px; box-sizing: border-box; }
.field input:disabled { opacity: 0.6; }
.field input:focus, .field select:focus { outline: 2px solid var(--grad-a); outline-offset: 1px; }

.segments-list { display: flex; flex-direction: column; gap: 8px; margin-top: 12px; }
.segment-row { display: flex; align-items: center; gap: 6px; background: var(--bg); border-radius: 14px; padding: 8px 10px; }
.segment-index { font-size: 11px; font-weight: 800; color: white; background: var(--grad-a); width: 18px; height: 18px; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.segment-row input[type="time"] { border: none; background: transparent; font-size: 13px; padding: 4px 2px; width: 78px; min-width: 0; font-family: 'Zen Kaku Gothic New', sans-serif; color: var(--ink); }
.segment-sep { font-size: 11px; color: var(--ink-soft); flex-shrink: 0; }
.segment-wage { border: none; background: var(--card); border-radius: 10px; font-size: 13px; padding: 6px 8px; width: 64px; min-width: 0; font-family: 'Zen Kaku Gothic New', sans-serif; color: var(--ink); flex: 1; }
.segment-del { border: none; background: transparent; color: var(--ink-soft); cursor: pointer; padding: 4px; display: flex; flex-shrink: 0; }
.segment-del:active { color: var(--down); }
.add-segment-btn { display: flex; align-items: center; gap: 5px; border: none; background: none; color: var(--grad-a); font-size: 12px; font-weight: 700; cursor: pointer; padding: 8px 2px; }

.break-hint { display: flex; align-items: center; gap: 5px; font-size: 11px; color: #B8862B; margin: 8px 0 0; line-height: 1.4; }
.break-note { font-size: 10.5px; color: var(--ink-soft); line-height: 1.5; margin: 6px 0 0; }
.break-note-warn { color: #B45309; }
.break-note-ok { color: var(--up); }
.profile-hint { display: flex; align-items: center; gap: 5px; font-size: 10.5px; color: var(--grad-a); margin: 6px 0 0; line-height: 1.4; }

.advanced-toggle { display: flex; align-items: center; gap: 5px; border: none; background: none; color: var(--ink-soft); font-size: 11.5px; font-weight: 700; cursor: pointer; padding: 10px 2px 2px; }

.preview-card { background: var(--bg); border-radius: 16px; padding: 14px; margin-top: 14px; display: flex; flex-direction: column; gap: 3px; }
.preview-lines { display: flex; flex-direction: column; gap: 3px; margin-top: 6px; }
.preview-line { display: flex; justify-content: space-between; font-size: 12px; color: var(--ink-soft); }
.preview-top { display: flex; align-items: center; justify-content: space-between; }
.preview-amount { font-size: 19px; font-weight: 900; color: var(--up); }
.preview-hours { font-size: 11px; color: var(--ink-soft); }
.preview-caption { font-size: 10px; color: var(--ink-soft); line-height: 1.5; margin: 6px 0 0; }

.badge-row { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 4px; }
.badge { font-size: 10px; font-weight: 700; background: #FEF3C7; color: #B45309; border-radius: 999px; padding: 3px 8px; }
.badge.holiday { background: #FEE2E6; color: var(--down); }
.badge.scheduled { background: #E0F2FE; color: #0369A1; }
.badge.precision { background: #DCFCE7; color: #15803D; }
.badge.precision.approx { background: #FEF3C7; color: #B45309; }
.badge.transport { background: #DBEAFE; color: #1D4ED8; }

.template-save-row { display: flex; align-items: center; gap: 8px; font-size: 12.5px; color: var(--ink-soft); margin-top: 14px; cursor: pointer; }
.template-save-row input[type="checkbox"] { width: 17px; height: 17px; accent-color: var(--grad-a); flex-shrink: 0; }
.template-name-input { margin-top: 8px; width: 100%; font-family: 'Zen Kaku Gothic New', sans-serif; font-size: 14px; padding: 10px 12px; border: none; border-radius: 14px; background: var(--bg); color: var(--ink); }

.primary-btn { display: flex; align-items: center; justify-content: center; gap: 7px; width: 100%; border: none; border-radius: 999px; padding: 13px; font-size: 14px; font-weight: 800; cursor: pointer; color: white; background: linear-gradient(135deg, var(--grad-a), var(--grad-b)); box-shadow: 0 8px 16px -6px rgba(109,93,246,0.5); min-height: 48px; margin-top: 16px; }
.primary-btn.expense { background: linear-gradient(135deg, #F97316, #F43F5E); box-shadow: 0 8px 16px -6px rgba(244,63,94,0.4); }
.primary-btn:active { filter: brightness(0.94); }
.warn-box { background: #FEF2F2; border-radius: 12px; padding: 8px 10px; margin-top: 10px; }
.anomaly-box { background: #FFFBEB; border-radius: 12px; padding: 8px 10px; margin-top: 10px; }
.anomaly-text { display: flex; align-items: flex-start; gap: 5px; font-size: 11.5px; color: #B45309; font-weight: 600; line-height: 1.4; margin: 2px 0; }
.form-warn { color: var(--down); font-size: 12px; font-weight: 600; }

.entry-card { display: flex; align-items: stretch; gap: 10px; background: var(--bg); border-radius: 16px; padding: 12px 12px 12px 0; margin-bottom: 8px; overflow: hidden; }
.entry-card:last-child { margin-bottom: 0; }
.entry-accent { width: 4px; border-radius: 4px; flex-shrink: 0; }
.entry-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.entry-body-btn { border: none; background: transparent; text-align: left; cursor: pointer; padding: 0; font-family: 'Zen Kaku Gothic New', sans-serif; }
.entry-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.entry-name { font-size: 13.5px; font-weight: 700; }
.entry-amount { font-size: 13.5px; font-weight: 800; flex-shrink: 0; }
.entry-amount.up { color: var(--up); }
.entry-amount.down { color: var(--down); }
.entry-sub { font-size: 11.5px; color: var(--ink-soft); }
.del-btn { border: none; background: transparent; color: var(--ink-soft); cursor: pointer; padding: 8px; display: flex; align-items: center; flex-shrink: 0; }
.del-btn:active { color: var(--down); }

.profile-row-btn { border: none; background: transparent; text-align: left; cursor: pointer; padding: 0; flex: 1; font-family: 'Zen Kaku Gothic New', sans-serif; }

.accordion-item { border-bottom: 1px solid var(--line); }
.accordion-item:last-of-type { border-bottom: none; }
.accordion-head { display: flex; align-items: center; justify-content: space-between; width: 100%; border: none; background: transparent; padding: 9px 0; cursor: pointer; font-family: 'Zen Kaku Gothic New', sans-serif; }
.accordion-body { padding: 0 0 10px; display: flex; flex-direction: column; gap: 5px; }
.accordion-line { display: flex; justify-content: space-between; font-size: 11.5px; color: var(--ink-soft); background: var(--bg); border-radius: 10px; padding: 6px 10px; }
.hours-summary { background: var(--bg); border-radius: 14px; padding: 10px 14px; margin-bottom: 10px; display: flex; flex-direction: column; gap: 4px; }
.hours-row { display: flex; justify-content: space-between; font-size: 12.5px; color: var(--ink-soft); }
.hours-row.accent { color: var(--ink); font-weight: 700; }
.approx-note { display: flex; align-items: flex-start; gap: 5px; font-size: 10.5px; color: #B45309; background: #FFFBEB; border-radius: 10px; padding: 7px 10px; margin: -2px 0 10px; line-height: 1.5; }
.accordion-line-group { background: var(--bg); border-radius: 12px; padding: 6px 10px; display: flex; flex-direction: column; gap: 3px; }
.accordion-line-head { background: transparent; padding: 0; font-weight: 700; color: var(--ink); }
.formula-line { font-size: 10.5px; color: var(--ink-soft); padding-left: 4px; }
.threshold-row { display: flex; align-items: center; justify-content: space-between; background: var(--bg); border-radius: 12px; padding: 8px 12px; margin-bottom: 10px; }
.threshold-input { width: 60px; border: none; background: var(--card); border-radius: 8px; padding: 6px 8px; font-size: 13px; text-align: center; font-family: 'Zen Kaku Gothic New', sans-serif; color: var(--ink); }

.flow-card { display: flex; align-items: center; justify-content: space-between; background: var(--card); border-radius: 20px; padding: 14px 10px; box-shadow: 0 1px 3px rgba(29,27,46,0.05); gap: 4px; }
.flow-box { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 2px; text-align: center; }
.flow-box.highlight .flow-amount { color: var(--grad-a); font-weight: 900; }
.flow-label { font-size: 10px; color: var(--ink-soft); font-weight: 700; }
.flow-amount { font-size: 13px; font-weight: 800; }
.flow-amount.up { color: var(--up); }
.flow-amount.down { color: var(--down); }
.flow-arrow { color: var(--ink-soft); flex-shrink: 0; }

.reason-chips { display: flex; flex-wrap: wrap; gap: 6px; }
.reason-chip { border: 1px solid var(--line); background: var(--bg); color: var(--ink-soft); border-radius: 999px; padding: 6px 11px; font-size: 11.5px; font-weight: 600; cursor: pointer; }
.reason-chip.active { background: var(--grad-a); color: white; border-color: var(--grad-a); }

.compare-section-title { font-size: 11.5px; font-weight: 800; color: var(--ink-soft); margin: 0 0 6px; text-transform: uppercase; letter-spacing: 0.03em; }
.compare-header { display: grid; grid-template-columns: 1.3fr 0.9fr 0.9fr 0.9fr; gap: 6px; font-size: 10px; color: var(--ink-soft); font-weight: 700; padding: 0 2px 4px; }
.compare-row { display: grid; grid-template-columns: 1.3fr 0.9fr 0.9fr 0.9fr; gap: 6px; align-items: center; padding: 5px 2px; border-bottom: 1px solid var(--line); }
.compare-row:last-of-type { border-bottom: none; }
.compare-label { font-size: 11.5px; color: var(--ink); }
.compare-app { font-size: 11.5px; color: var(--ink-soft); font-family: 'Zen Kaku Gothic New', sans-serif; }
.compare-input { width: 100%; border: none; background: var(--bg); border-radius: 8px; padding: 5px 6px; font-size: 11px; font-family: 'Zen Kaku Gothic New', sans-serif; color: var(--ink); min-width: 0; }
.compare-diff { font-size: 11px; font-weight: 700; color: var(--ink-soft); text-align: right; }
.compare-diff.up { color: var(--up); }
.compare-diff.down { color: var(--down); }
.compare-hint-warn { display: flex; align-items: flex-start; gap: 5px; font-size: 10.5px; color: #B45309; background: #FFFBEB; border-radius: 10px; padding: 8px 10px; margin: 10px 0 0; line-height: 1.5; }
.compare-hint-ok { font-size: 11px; color: var(--up); font-weight: 700; margin: 10px 0 0; }

.data-btn-row { display: flex; flex-wrap: wrap; gap: 8px; }
.data-btn { display: flex; align-items: center; gap: 6px; border: none; background: var(--bg); color: var(--ink); border-radius: 12px; padding: 9px 12px; font-size: 12px; font-weight: 700; cursor: pointer; }
.data-btn:active { background: #E7E4FE; }

.fab { position: fixed; bottom: 86px; right: max(16px, calc(50% - 194px)); width: 56px; height: 56px; border-radius: 50%; border: none; background: linear-gradient(135deg, var(--grad-a), var(--grad-b)); color: white; display: flex; align-items: center; justify-content: center; box-shadow: 0 10px 22px -6px rgba(109,93,246,0.55); cursor: pointer; z-index: 11; }
.fab:active { filter: brightness(0.94); transform: scale(0.96); }

.bottom-nav { position: fixed; bottom: 12px; left: 50%; transform: translateX(-50%); width: calc(100% - 32px); max-width: 388px; background: var(--card); border-radius: 24px; display: flex; padding: 6px; box-shadow: 0 10px 30px -8px rgba(29,27,46,0.25); z-index: 10; }
.nav-btn { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 2px; padding: 9px 2px; border: none; background: transparent; color: var(--ink-soft); border-radius: 18px; cursor: pointer; }
.nav-btn.active { background: var(--bg); color: var(--grad-a); }
.nav-label { font-size: 10px; font-weight: 700; }

@media (max-width: 360px) {
  .hero-amount { font-size: 28px; }
  .form-grid { grid-template-columns: 1fr; }
  .field.half { grid-column: span 1; }
  .segment-row { flex-wrap: wrap; }
  .flow-label { font-size: 9px; }
  .flow-amount { font-size: 11px; }
}
`;
