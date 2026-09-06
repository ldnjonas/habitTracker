/// Beschriftungen — wortgleich mit `HabitUI/Support.swift`.
///
/// Bewusst von Hand statt über `Intl`: die Mac-App schreibt „4. September 2026"
/// und keinen von der Systemsprache abhängigen Text, und dieselbe App soll auf
/// beiden Geräten dasselbe sagen. `Intl` würde außerdem einen Kalendertag durch
/// eine `Date` schleusen — und die kennt eine Zeitzone, die hier keine Rolle
/// spielen darf.

import type { CalendarDate, Schedule, Weekday } from "../api/types.ts";

const MONATE = [
  "Januar", "Februar", "März", "April", "Mai", "Juni",
  "Juli", "August", "September", "Oktober", "November", "Dezember",
];

const WOCHENTAGE = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];

const TAGE_LANG = [
  "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag",
];

function teile(datum: CalendarDate): { jahr: number; monat: number; tag: number } {
  return {
    jahr: Number(datum.slice(0, 4)),
    monat: Number(datum.slice(5, 7)),
    tag: Number(datum.slice(8, 10)),
  };
}

/// „4. September 2026"
export function langesDatum(datum: CalendarDate): string {
  const { jahr, monat, tag } = teile(datum);
  return `${tag}. ${MONATE[monat - 1]} ${jahr}`;
}

/// „4. Sep."
export function kurzesDatum(datum: CalendarDate): string {
  const { monat, tag } = teile(datum);
  return `${tag}. ${MONATE[monat - 1]!.slice(0, 3)}.`;
}

/// ISO-Wochentag, ohne den Umweg über `Date`: Montag ist 1.
export function wochentag(datum: CalendarDate): Weekday {
  const { jahr, monat, tag } = teile(datum);
  // Hinnants Zivilkalender, dieselbe Rechnung wie in `domain/calendar.ts`.
  const div = (a: number, b: number) => Math.trunc(a / b);
  const y = jahr - (monat <= 2 ? 1 : 0);
  const era = div(y >= 0 ? y : y - 399, 400);
  const yoe = y - era * 400;
  const doy = div(153 * (monat + (monat > 2 ? -3 : 9)) + 2, 5) + tag - 1;
  const doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy;
  const nummer = era * 146097 + doe - 719468;
  return ((((nummer + 3) % 7) + 7) % 7 + 1) as Weekday;
}

export function langerWochentag(datum: CalendarDate): string {
  return TAGE_LANG[wochentag(datum) - 1]!;
}

export function planText(plan: Schedule): string {
  switch (plan.kind) {
    case "daily":
      return "Täglich";
    case "weekdays":
      return plan.days.length === 7
        ? "Täglich"
        : [...plan.days].sort((a, b) => a - b).map((t) => WOCHENTAGE[t - 1]).join(", ");
    case "timesPerWeek":
      return `${plan.n}× pro Woche`;
    case "everyNDays":
      return plan.n === 1 ? "Täglich" : `Alle ${plan.n} Tage`;
  }
}

/// Zahlen mit Komma und höchstens zwei Stellen — „2,5" statt „2.5".
export function zahl(wert: number): string {
  return wert
    .toLocaleString("de-DE", { maximumFractionDigits: 2 })
    .replace(" ", " ");
}

export const STATUS_TEXT: Record<string, string> = {
  completed: "Erledigt",
  partial: "Offen",
  missed: "Verpasst",
  frozen: "Eingefroren",
  paused: "Pausiert",
  skipped: "Übersprungen",
  notScheduled: "Nicht geplant",
  future: "Noch nicht",
};
