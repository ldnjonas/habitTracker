/// Portiert aus `apple/HabitKit/Sources/HabitCore/Focus.swift`.

import type { CalendarDate } from "./calendar.ts";
import { daysUntil, through } from "./calendar.ts";
import type { DayException, Entry } from "./entry.ts";
import type { Habit } from "./habit.ts";
import type { Timestamp } from "./timestamp.ts";
import { type DaySummary, isPerfect, overview } from "./overview.ts";

/// Ein selbst gesetzter Zeitraum, in dem lückenlos alles erfüllt werden soll.
///
/// Der Streak fragt „wie lange schon?", der Fokus fragt „schaffe ich *diese*
/// sieben Tage?". Das ist ein anderes Versprechen: es hat einen Anfang, ein
/// Ende und ein Ergebnis — und man kann es verlieren, ohne alles zu verlieren.
///
/// **Gespeichert wird nur die Absicht, nie das Ergebnis.** Ob ein Lauf
/// durchgezogen wurde, ergibt sich aus den Einträgen. Ein gespeichertes
/// „geschafft" würde von ihnen abdriften, sobald ein Tag nachträglich korrigiert
/// wird — und wäre dann eine Auszeichnung für etwas, das nicht mehr stimmt.
export type FocusRun = {
  id: string;
  userId: string;
  /// Frei wählbar; ohne Angabe zeigt die Oberfläche „7-Tage-Fokus".
  title?: string | null;
  startsOn: CalendarDate;
  /// Einschließlich — ein 7-Tage-Fokus ab Montag endet am Sonntag.
  endsOn: CalendarDate;
  /// Leer heißt: alle Habits, auch später angelegte.
  ///
  /// Bewusst eine Momentaufnahme der Absicht und kein Fremdschlüssel: ein
  /// später gelöschter Habit soll den Verlaufseintrag nicht mitreißen.
  habitIds: string[];
  /// Selbst beendet. Ehrlicher, als einen Lauf still verrotten zu lassen.
  abandonedOn?: CalendarDate | null;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
};

export function totalDays(run: FocusRun): number {
  return daysUntil(run.startsOn, run.endsOn) + 1;
}

export function covers(run: FocusRun, date: CalendarDate): boolean {
  return date >= run.startsOn && date <= run.endsOn;
}

/// Ob dieser Habit zum Lauf gehört.
export function includes(run: FocusRun, habitId: string): boolean {
  return run.habitIds.length === 0 || run.habitIds.includes(habitId);
}

export function defaultTitle(run: FocusRun): string {
  return `${totalDays(run)}-Tage-Fokus`;
}

export function displayTitle(run: FocusRun): string {
  return run.title && run.title.length > 0 ? run.title : defaultTitle(run);
}

/// Wie ein Lauf ausgegangen ist — oder gerade steht.
export type FocusOutcome =
  /// Beginnt erst noch.
  | { readonly code: "upcoming" }
  /// Läuft und ist bislang lückenlos.
  | { readonly code: "running"; readonly dayNumber: number; readonly totalDays: number }
  /// Bis zum letzten Tag durchgehalten.
  | { readonly code: "completed" }
  /// An diesem Tag ist eine Lücke geblieben.
  | { readonly code: "failed"; readonly on: CalendarDate }
  /// Vom Nutzer selbst beendet.
  | { readonly code: "abandoned"; readonly on: CalendarDate };

/// Ob der Lauf noch offen ist.
export function isOpen(outcome: FocusOutcome): boolean {
  return outcome.code === "upcoming" || outcome.code === "running";
}

export function isSuccess(outcome: FocusOutcome): boolean {
  return outcome.code === "completed";
}

/// Ein ausgewerteter Lauf.
export type FocusProgress = {
  run: FocusRun;
  outcome: FocusOutcome;
  /// Je Tag des Fensters, auch für Tage in der Zukunft.
  days: Record<string, DaySummary>;
  /// Tage, an denen alles Anstehende erledigt war.
  perfectDays: number;
  /// Tage des Fensters, an denen überhaupt etwas anstand.
  ///
  /// Der ehrliche Nenner. Ein Fokus über einen Mo/Mi/Fr-Habit hat in sieben
  /// Tagen nur drei zu vergebende — „3 von 7" neben „durchgezogen" zu zeigen
  /// widerspräche sich selbst.
  plannedDays: number;
  /// Bereits vergangene Tage des Fensters, heute eingeschlossen.
  elapsedDays: number;
};

/// Fortschritt 0…1 für den Ring in der Oberfläche.
///
/// Ein Fenster ohne einen einzigen geplanten Tag ist vollständig, nicht leer.
export function fraction(progress: FocusProgress): number {
  return progress.plannedDays > 0 ? progress.perfectDays / progress.plannedDays : 1;
}

/// Wertet einen Lauf gegen die Einträge aus.
///
/// Die Regel ist bewusst dieselbe wie in der Übersicht: ein Tag ist geschafft,
/// wenn alles erledigt ist, was an ihm *verpflichtend* war. Damit gilt auch hier,
/// dass ein `timesPerWeek`-Habit einen einzelnen Tag nicht reißen kann und dass
/// Urlaub den Tag herausnimmt — während ein Streak Freeze ihn *nicht* rettet:
/// ein Fokus ist das strengere Versprechen.
///
/// Ein Tag ohne Plan bricht nichts. Der laufende Tag ebenfalls nicht, solange
/// er noch offen ist — sonst stünde jeder Fokus jeden Morgen als gescheitert da.
export function evaluate(
  run: FocusRun,
  habits: Habit[],
  entries: Entry[],
  exceptions: DayException[],
  today: CalendarDate,
): FocusProgress {
  const participating = habits.filter((h) => includes(run, h.id));
  const summaries = overview(
    participating, entries, exceptions, run.startsOn, run.endsOn, today);

  const window = through(run.startsOn, run.endsOn);
  const perfectDays = window.filter((d) => {
    const s = summaries[d];
    return s ? isPerfect(s) : false;
  }).length;
  const plannedDays = window.filter(
    (d) => d <= today && (summaries[d]?.scheduled ?? 0) > 0).length;
  const elapsed = today < run.startsOn
    ? 0
    : Math.min(totalDays(run), daysUntil(run.startsOn, today) + 1);

  const progress = (outcome: FocusOutcome): FocusProgress => ({
    run, outcome, days: summaries,
    perfectDays, plannedDays, elapsedDays: elapsed,
  });

  // Selbst beendet schlägt alles andere — auch einen Lauf, der rechnerisch
  // noch zu retten wäre.
  if (run.abandonedOn != null) return progress({ code: "abandoned", on: run.abandonedOn });
  if (today < run.startsOn) return progress({ code: "upcoming" });

  // Der erste vergangene Tag mit einer Lücke entscheidet.
  for (const date of window) {
    if (date >= today) continue;
    const summary = summaries[date];
    if (summary && summary.scheduled > 0 && !isPerfect(summary)) {
      return progress({ code: "failed", on: date });
    }
  }

  if (run.endsOn < today) return progress({ code: "completed" });
  // Letzter Tag und heute schon vollständig: das Ergebnis steht, ohne dass
  // man bis Mitternacht warten muss.
  if (run.endsOn === today) {
    const summary = summaries[today];
    if (summary && (summary.scheduled === 0 || isPerfect(summary))) {
      return progress({ code: "completed" });
    }
  }
  return progress({ code: "running", dayNumber: elapsed, totalDays: totalDays(run) });
}

/// Bilanz über alle Läufe — die Kopfzeile des Fokus-Tabs.
export type FocusRecord = {
  completed: number;
  failed: number;
  abandoned: number;
  /// Längste Kette unmittelbar aufeinander folgender geschaffter Läufe.
  longestWinStreak: number;
};

export function finished(bilanz: FocusRecord): number {
  return bilanz.completed + bilanz.failed + bilanz.abandoned;
}

/// Anteil geschaffter an abgeschlossenen Läufen, `null` ohne abgeschlossenen.
export function successRate(bilanz: FocusRecord): number | null {
  const gesamt = finished(bilanz);
  return gesamt === 0 ? null : bilanz.completed / gesamt;
}

/// Bilanziert abgeschlossene Läufe. Laufende und künftige bleiben draußen —
/// ein noch offener Lauf ist weder Erfolg noch Misserfolg.
export function record(outcomes: FocusOutcome[]): FocusRecord {
  let completed = 0, failed = 0, abandoned = 0;
  let streak = 0, longest = 0;

  for (const outcome of outcomes) {
    switch (outcome.code) {
      case "completed":
        completed += 1;
        streak += 1;
        longest = Math.max(longest, streak);
        break;
      case "failed":
        failed += 1;
        streak = 0;
        break;
      case "abandoned":
        abandoned += 1;
        streak = 0;
        break;
      case "upcoming":
      case "running":
        continue; // unterbricht die Kette nicht, zählt aber nicht mit
    }
  }

  return { completed, failed, abandoned, longestWinStreak: longest };
}
