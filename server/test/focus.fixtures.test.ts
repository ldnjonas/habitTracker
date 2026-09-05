/// Die Fokus-Fixtures, gerechnet von der TypeScript-Domäne.
///
/// Das Gegenstück zu `FocusFixtureTests.swift`.

import { test } from "node:test";
import assert from "node:assert/strict";

import type { CalendarDate } from "../src/domain/calendar.ts";
import type { ExceptionKind } from "../src/domain/entry.ts";
import {
  type FocusOutcome, type FocusRun,
  evaluate, finished, fraction, record, successRate, totalDays,
} from "../src/domain/focus.ts";
import {
  type HabitSpec, EPOCHE, buildEntry, buildException, buildHabits, loadFixtures,
} from "./fixtures.ts";

type Fixture = {
  name: string;
  today: CalendarDate;
  habits: HabitSpec[];
  entries: { habit: string; date: CalendarDate; value: number }[];
  exceptions: { habit: string | null; date: CalendarDate; kind: ExceptionKind }[];
  /// Ein einzelner Lauf, der gegen die Einträge ausgewertet wird.
  run?: {
    startsOn: CalendarDate;
    endsOn: CalendarDate;
    /// Schlüssel der beteiligten Habits; fehlt = alle.
    habits?: string[];
    abandonedOn?: CalendarDate;
    title?: string;
  };
  /// Fertige Ergebnisse für die Bilanz — dafür braucht es keine Einträge.
  outcomes?: FocusOutcome[];
  expected: {
    outcome?: string;
    /// Bei `failed` und `abandoned`: der Tag.
    on?: CalendarDate;
    dayNumber?: number;
    totalDays?: number;
    perfectDays?: number;
    plannedDays?: number;
    elapsedDays?: number;
    fraction?: number;
    record?: {
      completed?: number; failed?: number; abandoned?: number;
      finished?: number; successRate?: number | null; longestWinStreak?: number;
    };
  };
};

const fixtures = loadFixtures<Fixture>("focus");

test("spec/fixtures/focus liegt am erwarteten Ort und ist nicht leer", () => {
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
    const e = fixture.expected;

    if (fixture.run) {
      const entries = fixture.entries.map(
        (x, i) => buildEntry(habitId(x.habit), x.date, x.value, i));
      const exceptions = fixture.exceptions.map(
        (x, i) => buildException(x.habit == null ? null : habitId(x.habit), x.date, x.kind, i));

      const run: FocusRun = {
        id: "00000000-0000-0000-0000-00000000f0c0",
        userId: "local",
        title: fixture.run.title ?? null,
        startsOn: fixture.run.startsOn,
        endsOn: fixture.run.endsOn,
        habitIds: (fixture.run.habits ?? []).map(habitId),
        abandonedOn: fixture.run.abandonedOn ?? null,
        createdAt: EPOCHE,
        updatedAt: EPOCHE,
      };

      const progress = evaluate(run, habits, entries, exceptions, fixture.today);

      if (e.outcome !== undefined) {
        assert.equal(progress.outcome.code, e.outcome, "outcome");
      }
      if (e.on !== undefined) {
        const outcome = progress.outcome;
        assert.ok(outcome.code === "failed" || outcome.code === "abandoned",
          `outcome ${outcome.code} trägt keinen Tag`);
        assert.equal(outcome.on, e.on, "outcome.on");
      }
      if (e.dayNumber !== undefined) {
        assert.equal(progress.outcome.code, "running", "dayNumber gibt es nur bei running");
        assert.equal((progress.outcome as { dayNumber: number }).dayNumber, e.dayNumber,
          "dayNumber");
      }
      if (e.totalDays !== undefined) {
        assert.equal(totalDays(progress.run), e.totalDays, "totalDays");
      }
      if (e.perfectDays !== undefined) {
        assert.equal(progress.perfectDays, e.perfectDays, "perfectDays");
      }
      if (e.plannedDays !== undefined) {
        assert.equal(progress.plannedDays, e.plannedDays, "plannedDays");
      }
      if (e.elapsedDays !== undefined) {
        assert.equal(progress.elapsedDays, e.elapsedDays, "elapsedDays");
      }
      if (e.fraction !== undefined) {
        assert.ok(Math.abs(fraction(progress) - e.fraction) < 1e-9,
          `fraction — erwartet ${e.fraction}, war ${fraction(progress)}`);
      }
    }

    if (e.record) {
      assert.ok(fixture.outcomes, "record erwartet, aber keine outcomes im Fixture");
      const bilanz = record(fixture.outcomes);
      if (e.record.completed !== undefined) {
        assert.equal(bilanz.completed, e.record.completed, "completed");
      }
      if (e.record.failed !== undefined) {
        assert.equal(bilanz.failed, e.record.failed, "failed");
      }
      if (e.record.abandoned !== undefined) {
        assert.equal(bilanz.abandoned, e.record.abandoned, "abandoned");
      }
      if (e.record.finished !== undefined) {
        assert.equal(finished(bilanz), e.record.finished, "finished");
      }
      if (e.record.longestWinStreak !== undefined) {
        assert.equal(bilanz.longestWinStreak, e.record.longestWinStreak, "longestWinStreak");
      }
      if (e.record.successRate === null) {
        assert.equal(successRate(bilanz), null, "successRate müsste null sein");
      } else if (e.record.successRate !== undefined) {
        const quote = successRate(bilanz);
        assert.ok(quote != null, "successRate fehlt");
        assert.ok(Math.abs(quote - e.record.successRate) < 1e-9,
          `successRate — erwartet ${e.record.successRate}, war ${quote}`);
      }
    }
  });
}
