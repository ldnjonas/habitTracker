/// Auswertungen — dünne Hüllen um `domain/`.
///
/// Hier steht bewusst keine Rechnung, nur das Zusammensuchen der Zeilen. Die
/// Zahlen kommen aus derselben Domäne, die auch die Mac-App benutzt; läge hier
/// eine zweite Fassung, zeigten Mac und Browser für denselben Bestand
/// Verschiedenes.

import type { FastifyInstance } from "fastify";
import type { Db } from "../db.ts";
import { type CalendarDate, addDays, addMonths, through } from "../domain/calendar.ts";
import { correlations } from "../domain/correlations.ts";
import { status } from "../domain/completion.ts";
import { isScheduled } from "../domain/resolution.ts";
import { overview, overviewStats } from "../domain/overview.ts";
import { stats } from "../domain/stats.ts";
import { periodTotal } from "../domain/totals.ts";
import { trend } from "../domain/trend.ts";
import * as store from "../store.ts";
import { datum, pfad, zeitraum } from "./helfer.ts";

/// Wie weit die Streak-Berechnung für die Heute-Ansicht zurückreicht.
///
/// Dieselbe Spanne wie in der Mac-App: ein Streak, der länger als gut ein Jahr
/// ist, wird hier nicht mehr vollständig gezählt — dafür bleibt der Aufruf
/// schnell genug für eine Ansicht, die bei jedem Antippen neu lädt.
const STREAK_FENSTER = 400;

export function insightRouten(app: FastifyInstance, db: Db): void {

  app.get("/habits/:habitId/totals", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    const { from, to } = zeitraum(anfrage);
    const habit = store.habitOderFehler(db, habitId);
    return periodTotal(habit, store.listEntries(db, from, to, habitId),
                       store.listEvents(db, habitId, from, to), from, to);
  });

  app.get("/habits/:habitId/stats", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    const { from, to } = zeitraum(anfrage);
    const habit = store.habitOderFehler(db, habitId);
    return stats(habit, store.listEntries(db, from, to, habitId),
                 store.listExceptions(db, from, to), from, to, store.heute());
  });

  // Das Aggregat für die Heute-Ansicht: ein Aufruf statt einer je Habit.
  //
  // Ohne `date` gilt der Tag des **Servers**. Absichtlich nicht der des
  // Browsers: der Server entscheidet ohnehin, was als Nachtrag gilt, und ein
  // Telefon in einer anderen Zeitzone bekäme sonst eine Liste für gestern und
  // eine 422 beim Abhaken. Die Antwort sagt deshalb immer, welcher Tag gemeint
  // war.
  app.get("/stats/summary", async (anfrage) => {
    const abfrage = anfrage.query as { date?: string };
    const today = store.heute();
    const tag = abfrage.date ? datum(abfrage.date, "date") : today;

    const alle = store.listHabits(db);
    // Nur was an diesem Tag zur Debatte steht — dieselbe Auswahl wie in der
    // Mac-App, wo `todaysHabits` auf `isScheduled` filtert.
    const faellig = alle.filter((h) => isScheduled(h, tag));

    // Einträge, Ausnahmen und Trend brauchen Vergangenheit; einmal für alle
    // geladen statt je Habit.
    const von = addDays(tag, -STREAK_FENSTER);
    const entries = store.listEntries(db, von, tag);
    const exceptions = store.listExceptions(db, von, tag);

    const habits = faellig.map((habit) => {
      const eigene = entries.filter((e) => e.habitId === habit.id);
      const eintrag = eigene.find((e) => e.date === tag);
      const auswertung = stats(habit, eigene, exceptions, von, tag, today);
      return {
        habitId: habit.id,
        status: auswertung.days[tag]?.code
          ?? status(habit, eintrag, undefined, tag, today).code,
        value: eintrag?.value ?? 0,
        currentStreak: auswertung.currentStreak,
        trend: trend(habit, eigene, exceptions, today)?.code ?? null,
      };
    });

    return {
      date: tag,
      dueCount: habits.length,
      completedCount: habits.filter((h) => h.status === "completed").length,
      habits,
    };
  });

  app.get("/stats/overview", async (anfrage) => {
    const { from, to } = zeitraum(anfrage);
    const today = store.heute();
    // Archivierte zählen mit: sie sind Teil des Verlaufs, den die Heatmap zeigt.
    const habits = store.listHabits(db, { includeArchived: true });

    const summaries = overview(
      habits, store.listEntries(db, from, to), store.listExceptions(db, from, to),
      from, to, today);
    const kennzahlen = overviewStats(summaries, from, to, today);

    return {
      days: through(from, to).map((d) => summaries[d]),
      perfectDays: kennzahlen.perfectDays,
      daysWithPlan: kennzahlen.daysWithPlan,
      totalCompletions: kennzahlen.totalCompletions,
      perfectStreak: kennzahlen.perfectStreak,
      // Bezugsgröße der Farbskala über zwölf Monate statt über den gezeigten
      // Ausschnitt — sonst bedeutete dieselbe Farbe in der Wochenansicht etwas
      // anderes als in der Jahresansicht.
      busiestDay: arbeitsreichsterTag(db, habits, to, today),
    };
  });

  app.get("/insights/correlations", async (anfrage) => {
    const { from, to } = zeitraum(anfrage);
    return correlations(
      store.listHabits(db, { includeArchived: true }),
      store.listEntries(db, from, to),
      store.listDayLogs(db, from, to),
      store.listExceptions(db, from, to),
      from, to, store.heute());
  });
}

/// Die höchste Zahl an Erledigungen an einem Tag der letzten zwölf Monate.
function arbeitsreichsterTag(
  db: Db, habits: ReturnType<typeof store.listHabits>,
  bis: CalendarDate, today: CalendarDate,
): number {
  const von = addMonths(bis, -12);
  const summaries = overview(
    habits, store.listEntries(db, von, bis), store.listExceptions(db, von, bis),
    von, bis, today);
  let hoechste = 0;
  for (const tag of through(von, bis)) {
    const summary = summaries[tag];
    if (summary && summary.completed > hoechste) hoechste = summary.completed;
  }
  return hoechste;
}
