/// Die Korrelations-Fixtures, gerechnet von der TypeScript-Domäne.
///
/// Das Gegenstück zu `CorrelationFixtureTests.swift`. Der eigentliche Gegenstand
/// dieser Fixtures ist die **Zurückhaltung**: die meisten erwarten keinen Befund.

import { test } from "node:test";
import assert from "node:assert/strict";

import type { CalendarDate } from "../src/domain/calendar.ts";
import type { DayLog, ExceptionKind } from "../src/domain/entry.ts";
import {
  type CorrelationStrength, type JournalMetric,
  CORRELATION_MINIMUM_DAYS, CORRELATION_MINIMUM_PER_GROUP,
  correlations, difference, pearson, requiredCoefficient, strengthOf,
} from "../src/domain/correlations.ts";
import {
  type HabitSpec, EPOCHE, buildEntry, buildException, buildHabits, loadFixtures,
} from "./fixtures.ts";

type Fixture = {
  name: string;
  today: CalendarDate;
  range: { from: CalendarDate; to: CalendarDate };
  habits: HabitSpec[];
  entries: { habit: string; date: CalendarDate; value: number }[];
  dayLogs: { date: CalendarDate; mood?: number; energy?: number; sleepHours?: number }[];
  exceptions: { habit: string | null; date: CalendarDate; kind: ExceptionKind }[];
  expected: {
    /// Genaue Zahl der Befunde.
    count?: number;
    minimumCount?: number;
    /// Befunde, die vorkommen müssen — geprüft wird, was dasteht.
    findings?: {
      habit: string;
      metric: JournalMetric;
      strength?: CorrelationStrength;
      coefficientAbove?: number;
      coefficientBelow?: number;
      completedAverage?: number;
      missedAverage?: number;
      difference?: number;
      dayCount?: number;
      completedDays?: number;
    }[];
    /// Größen, zu denen ausdrücklich **nichts** berichtet werden darf.
    absent?: JournalMetric[];
    first?: { metric: JournalMetric };
    /// Pearson unmittelbar, ohne den Umweg über Habits.
    pearson?: {
      completed: number[];
      missed: number[];
      value?: number | null;
      above?: number;
      belowRequiredForDays?: number;
    }[];
    required?: { days: number; value: number; tolerance: number }[];
    requiredIsMonotone?: { from: number; to: number; step: number };
    strengths?: { coefficient: number; strength: CorrelationStrength | null }[];
    minimumDays?: number;
    minimumPerGroup?: number;
  };
};

const fixtures = loadFixtures<Fixture>("correlations");

test("spec/fixtures/correlations liegt am erwarteten Ort und ist nicht leer", () => {
  assert.ok(fixtures.length > 0, "Keine Fixtures gefunden");
});

for (const { file, fixture } of fixtures) {
  test(`${file} — ${fixture.name}`, () => {
    const { habits, ids } = buildHabits(fixture.habits);
    const habitId = (key: string): string => {
      const id = ids.get(key);
      assert.ok(id, `Unbekannter Habit-Schlüssel: ${key}`);
      return id;
    };

    const entries = fixture.entries.map(
      (x, i) => buildEntry(habitId(x.habit), x.date, x.value, i));
    const exceptions = fixture.exceptions.map(
      (x, i) => buildException(x.habit == null ? null : habitId(x.habit), x.date, x.kind, i));
    const dayLogs: DayLog[] = fixture.dayLogs.map((log) => ({
      date: log.date, userId: "local",
      mood: log.mood ?? null, energy: log.energy ?? null, sleepHours: log.sleepHours ?? null,
      createdAt: EPOCHE, updatedAt: EPOCHE,
    }));

    const ergebnis = correlations(
      habits, entries, dayLogs, exceptions,
      fixture.range.from, fixture.range.to, fixture.today);
    const e = fixture.expected;

    if (e.count !== undefined) {
      assert.equal(ergebnis.length, e.count,
        `Zahl der Befunde: ${JSON.stringify(ergebnis.map((k) => [k.metric, k.coefficient]))}`);
    }
    if (e.minimumCount !== undefined) {
      assert.ok(ergebnis.length >= e.minimumCount,
        `mindestens ${e.minimumCount} Befunde, waren ${ergebnis.length}`);
    }
    for (const metrik of e.absent ?? []) {
      assert.equal(ergebnis.find((k) => k.metric === metrik), undefined,
        `${metrik} dürfte nicht berichtet werden`);
    }
    if (e.first) {
      assert.ok(ergebnis.length > 0, "kein Befund, aber einer erwartet");
      assert.equal(ergebnis[0]!.metric, e.first.metric, "der deutlichste steht vorn");
    }

    for (const erwartet of e.findings ?? []) {
      const id = habitId(erwartet.habit);
      const befund = ergebnis.find((k) => k.habitId === id && k.metric === erwartet.metric);
      assert.ok(befund, `Kein Befund für ${erwartet.habit}/${erwartet.metric}`);
      const nah = (a: number, b: number) => Math.abs(a - b) < 1e-9;
      if (erwartet.strength !== undefined) {
        assert.equal(befund.strength, erwartet.strength, "strength");
      }
      if (erwartet.coefficientAbove !== undefined) {
        assert.ok(befund.coefficient > erwartet.coefficientAbove,
          `coefficient ${befund.coefficient} > ${erwartet.coefficientAbove}`);
      }
      if (erwartet.coefficientBelow !== undefined) {
        assert.ok(befund.coefficient < erwartet.coefficientBelow,
          `coefficient ${befund.coefficient} < ${erwartet.coefficientBelow}`);
      }
      if (erwartet.completedAverage !== undefined) {
        assert.ok(nah(befund.completedAverage, erwartet.completedAverage), "completedAverage");
      }
      if (erwartet.missedAverage !== undefined) {
        assert.ok(nah(befund.missedAverage, erwartet.missedAverage), "missedAverage");
      }
      if (erwartet.difference !== undefined) {
        assert.ok(nah(difference(befund), erwartet.difference),
          `difference — erwartet ${erwartet.difference}, war ${difference(befund)}`);
      }
      if (erwartet.dayCount !== undefined) {
        assert.equal(befund.dayCount, erwartet.dayCount, "dayCount");
      }
      if (erwartet.completedDays !== undefined) {
        assert.equal(befund.completedDays, erwartet.completedDays, "completedDays");
      }
    }

    for (const fall of e.pearson ?? []) {
      const r = pearson(fall.completed, fall.missed);
      if (fall.value === null) {
        assert.equal(r, null, "pearson müsste null sein");
        continue;
      }
      assert.ok(r != null, "pearson fehlt");
      if (fall.value !== undefined) {
        assert.ok(Math.abs(r - fall.value) < 1e-9, `pearson — erwartet ${fall.value}, war ${r}`);
      }
      if (fall.above !== undefined) {
        assert.ok(r > fall.above, `pearson ${r} > ${fall.above}`);
      }
      if (fall.belowRequiredForDays !== undefined) {
        const huerde = requiredCoefficient(fall.belowRequiredForDays);
        assert.ok(r < huerde, `pearson ${r} < Hürde ${huerde}`);
      }
    }

    for (const fall of e.required ?? []) {
      const actual = requiredCoefficient(fall.days);
      assert.ok(Math.abs(actual - fall.value) < fall.tolerance,
        `Hürde bei ${fall.days} Tagen — erwartet ${fall.value}, war ${actual}`);
    }

    if (e.requiredIsMonotone) {
      const { from, to, step } = e.requiredIsMonotone;
      for (let tage = from; tage < to; tage += step) {
        assert.ok(requiredCoefficient(tage) >= requiredCoefficient(tage + step),
          `Mehr Daten dürfen die Hürde nie anheben: ${tage} → ${tage + step}`);
      }
    }

    for (const fall of e.strengths ?? []) {
      assert.equal(strengthOf(fall.coefficient), fall.strength,
        `Stärke bei ${fall.coefficient}`);
    }

    if (e.minimumDays !== undefined) {
      assert.equal(CORRELATION_MINIMUM_DAYS, e.minimumDays, "minimumDays");
    }
    if (e.minimumPerGroup !== undefined) {
      assert.equal(CORRELATION_MINIMUM_PER_GROUP, e.minimumPerGroup, "minimumPerGroup");
    }
  });
}
