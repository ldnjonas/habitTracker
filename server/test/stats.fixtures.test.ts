/// Die Golden Fixtures, gerechnet von der TypeScript-Domäne.
///
/// Das Gegenstück zu `FixtureTests.swift`. Beide lesen dieselben Dateien und
/// prüfen dieselben Felder in derselben Reihenfolge.

import { test } from "node:test";
import assert from "node:assert/strict";

import type { CalendarDate } from "../src/domain/calendar.ts";
import { requireDate } from "../src/domain/calendar.ts";
import type { DayException, Entry, ExceptionKind } from "../src/domain/entry.ts";
import type { Habit, HabitKind } from "../src/domain/habit.ts";
import { LOCAL_USER_ID, sortRules } from "../src/domain/habit.ts";
import type { HabitRule } from "../src/domain/schedule.ts";
import { type StreakUnit, stats } from "../src/domain/stats.ts";
import { trend } from "../src/domain/trend.ts";
import type { Timestamp } from "../src/domain/timestamp.ts";
import { loadFixtures } from "./fixtures.ts";

type Fixture = {
  name: string;
  today: CalendarDate;
  range: { from: CalendarDate; to: CalendarDate };
  habit: {
    kind: HabitKind;
    rules: HabitRule[];
    startsOn?: CalendarDate;
    endsOn?: CalendarDate;
    archivedOn?: CalendarDate;
  };
  entries: { date: CalendarDate; value: number }[];
  exceptions: { date: CalendarDate; kind: ExceptionKind }[];
  expected: {
    streakUnit?: StreakUnit;
    currentStreak?: number;
    longestStreak?: number;
    completedCount?: number;
    evaluatedCount?: number;
    completionRate?: number | null;
    /// Nur die aufgeführten Tage werden geprüft, nicht der ganze Zeitraum.
    days?: Record<string, string>;
    weekdayBreakdown?: Record<string, number>;
    /// Zwei Ebenen von „fehlt": Schlüssel nicht vorhanden = nicht prüfen,
    /// Schlüssel mit `null` = es muss `null` herauskommen.
    trend?: string | null;
  };
};

/// Feste ID, damit Einträge und Habit zueinander finden.
const HABIT_ID = "00000000-0000-0000-0000-0000000000A1";
/// Die Zeitstempel spielen in dieser Auswertung keine Rolle — die Domäne
/// rechnet mit Kalendertagen. Ein fester Wert hält die Fixtures frei davon.
const EPOCHE = "1970-01-01T00:00:00.000Z" as Timestamp;

function buildHabit(f: Fixture): Habit {
  return sortRules({
    id: HABIT_ID,
    userId: LOCAL_USER_ID,
    name: f.name,
    kind: f.habit.kind,
    rules: f.habit.rules,
    colorHex: "#4F8DF7",
    symbol: "checkmark.circle",
    sortOrder: 0,
    tagIds: [],
    tracksTime: false,
    startsOn: f.habit.startsOn ?? null,
    endsOn: f.habit.endsOn ?? null,
    archivedOn: f.habit.archivedOn ?? null,
    createdAt: EPOCHE,
    updatedAt: EPOCHE,
  });
}

function buildEntries(f: Fixture): Entry[] {
  return f.entries.map((e, i) => ({
    id: `entry-${i}`,
    habitId: HABIT_ID,
    date: e.date,
    value: e.value,
    source: "manual",
    createdAt: EPOCHE,
    updatedAt: EPOCHE,
  }));
}

function buildExceptions(f: Fixture): DayException[] {
  return f.exceptions.map((x, i) => ({
    id: `exception-${i}`,
    habitId: null,
    date: x.date,
    kind: x.kind,
    createdAt: EPOCHE,
    updatedAt: EPOCHE,
  }));
}

const fixtures = loadFixtures<Fixture>("stats");

test("spec/fixtures/stats liegt am erwarteten Ort und ist nicht leer", () => {
  assert.ok(fixtures.length > 0, "Keine Fixtures gefunden");
});

for (const { file, fixture } of fixtures) {
  test(`${file} — ${fixture.name}`, () => {
    const habit = buildHabit(fixture);
    const entries = buildEntries(fixture);
    const exceptions = buildExceptions(fixture);
    const result = stats(
      habit, entries, exceptions,
      fixture.range.from, fixture.range.to, fixture.today,
    );
    const e = fixture.expected;

    if (e.streakUnit !== undefined) {
      assert.equal(result.streakUnit, e.streakUnit, "streakUnit");
    }
    if (e.currentStreak !== undefined) {
      assert.equal(result.currentStreak, e.currentStreak, "currentStreak");
    }
    if (e.longestStreak !== undefined) {
      assert.equal(result.longestStreak, e.longestStreak, "longestStreak");
    }
    if (e.completedCount !== undefined) {
      assert.equal(result.completedCount, e.completedCount, "completedCount");
    }
    if (e.evaluatedCount !== undefined) {
      assert.equal(result.evaluatedCount, e.evaluatedCount, "evaluatedCount");
    }
    // Wie bei `trend` zwei Ebenen von „fehlt": Schlüssel nicht vorhanden =
    // nicht prüfen, Schlüssel mit `null` = es muss `null` herauskommen.
    if (e.completionRate === null) {
      assert.equal(result.completionRate, null, "completionRate müsste null sein");
    } else if (e.completionRate !== undefined) {
      assert.ok(result.completionRate != null, "completionRate fehlt");
      assert.ok(Math.abs(result.completionRate - e.completionRate) < 1e-9,
        `completionRate — erwartet ${e.completionRate}, war ${result.completionRate}`);
    } else if (e.evaluatedCount === 0) {
      assert.equal(result.completionRate, null, "completionRate müsste null sein");
    }

    for (const [iso, code] of Object.entries(e.days ?? {})) {
      const date = requireDate(iso);
      const actual = result.days[date];
      assert.ok(actual, `${iso} fehlt im Zeitraum`);
      assert.equal(actual.code, code, `${iso}`);
    }

    for (const [raw, share] of Object.entries(e.weekdayBreakdown ?? {})) {
      const actual = result.weekdayBreakdown[Number(raw) as 1];
      assert.ok(actual !== undefined, `Wochentag ${raw} fehlt`);
      assert.ok(Math.abs(actual - share) < 1e-9,
        `Wochentag ${raw} — erwartet ${share}, war ${actual}`);
    }

    // `trend` doppelt optional: Schlüssel fehlt = nicht prüfen,
    // Schlüssel mit null = es muss null herauskommen.
    if ("trend" in e) {
      const actual = trend(habit, entries, exceptions, fixture.today);
      assert.equal(actual?.code ?? null, e.trend ?? null, "trend");
    }
  });
}
