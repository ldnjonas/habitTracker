/// Die Typen der API.
///
/// **Direkt aus `server/src/domain/` statt aus `spec/openapi.yaml` erzeugt.**
/// Der Plan sah `openapi-typescript` vor; der Grund dafür war, dass eine
/// Abweichung zwischen Server und Oberfläche ein Übersetzungsfehler sein soll
/// und kein Rätsel zur Laufzeit. Genau das erreicht der direkte Weg besser: die
/// Domäne des Servers *ist* TypeScript, also gibt es hier keine zweite
/// Beschreibung, die von ihr abweichen könnte — statt einer erzeugten Fassung,
/// die der Server womöglich nicht einhält.
///
/// Alles hier ist `import type`: im gebauten Bündel landet keine Zeile davon.

export type { CalendarDate, Weekday } from "../../../server/src/domain/calendar.ts";
export type { Timestamp } from "../../../server/src/domain/timestamp.ts";
export type { Habit, HabitKind, Tag } from "../../../server/src/domain/habit.ts";
export type { HabitRule, Schedule, Target } from "../../../server/src/domain/schedule.ts";
export type {
  DayException, DayLog, Entry, EntryEvent, ExceptionKind,
} from "../../../server/src/domain/entry.ts";
export type { DayStatus } from "../../../server/src/domain/dayStatus.ts";
export type { HabitStats, StreakUnit } from "../../../server/src/domain/stats.ts";
export type { DaySummary, IntensityScale } from "../../../server/src/domain/overview.ts";
export type { PeriodTotal } from "../../../server/src/domain/totals.ts";
export type { FocusProgress, FocusRun } from "../../../server/src/domain/focus.ts";
export type { FreezeEntry } from "../../../server/src/domain/freeze.ts";
export type { Correlation, JournalMetric } from "../../../server/src/domain/correlations.ts";
export type { BackupFile, ImportReport } from "../../../server/src/domain/backup.ts";

import type { CalendarDate } from "../../../server/src/domain/calendar.ts";
import type { DaySummary } from "../../../server/src/domain/overview.ts";
import type { FreezeEntry } from "../../../server/src/domain/freeze.ts";

/// Was `GET /stats/summary` liefert — das Aggregat für die Heute-Ansicht.
///
/// Ein Aufruf statt einer je Habit: auf dem Telefon ist jede Runde über das
/// Netz spürbar.
export type TagesUebersicht = {
  date: CalendarDate;
  dueCount: number;
  completedCount: number;
  habits: {
    habitId: string;
    status: string;
    value: number;
    currentStreak: number;
    trend: "improving" | "stable" | "declining" | null;
  }[];
};

export type UebersichtsAntwort = {
  days: DaySummary[];
  perfectDays: number;
  daysWithPlan: number;
  totalCompletions: number;
  perfectStreak: number;
  busiestDay: number;
};

export type FreezeKonto = {
  balance: number;
  maximum: number;
  ledger: FreezeEntry[];
};

export type PapierkorbEintrag = {
  table: "habit" | "tag" | "entry";
  rowId: string;
  deletedAt: string;
  label: string;
};
