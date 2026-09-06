/// Beschriftungen — wortgleich mit `HabitUI/Support.swift`.
///
/// Bewusst von Hand statt über `Intl`: die Mac-App schreibt „4. September 2026"
/// und keinen von der Systemsprache abhängigen Text, und dieselbe App soll auf
/// beiden Geräten dasselbe sagen. `Intl` würde außerdem einen Kalendertag durch
/// eine `Date` schleusen — und die kennt eine Zeitzone, die hier keine Rolle
/// spielen darf.

import type { CalendarDate, Schedule } from "../api/types.ts";
import { weekday } from "../../../server/src/domain/calendar.ts";

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

/// „Sep. 2025" — für Zeiträume, die über einen Jahreswechsel gehen. Ohne die
/// Jahreszahl steht dort sonst „1. Sep. – 6. Sep.", und das sind zwei Tage
/// statt eines Jahres.
export function monatJahr(datum: CalendarDate): string {
  const { jahr, monat } = teile(datum);
  return `${MONATE[monat - 1]!.slice(0, 3)}. ${jahr}`;
}

/// Der Wochentag kommt aus der Domäne des Servers — dieselbe Rechnung, die
/// auch die Auswertung benutzt. Ihn hier nachzubauen hieße, Hinnants
/// Zivilkalender ein drittes Mal zu schreiben.
export { weekday as wochentag };

export function langerWochentag(datum: CalendarDate): string {
  return TAGE_LANG[weekday(datum) - 1]!;
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
