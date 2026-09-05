/// Die Summen-Fixtures, gerechnet von der TypeScript-Domäne.
///
/// Das Gegenstück zu `TotalsFixtureTests.swift`.

import { test } from "node:test";
import assert from "node:assert/strict";

import type { CalendarDate } from "../src/domain/calendar.ts";
import type { EntryEvent } from "../src/domain/entry.ts";
import { durationMinutes, effectiveValue, hasValidInterval } from "../src/domain/entry.ts";
import type { Timestamp } from "../src/domain/timestamp.ts";
import {
  averagePerActiveDay, dayCount, periodTotal, sessions,
} from "../src/domain/totals.ts";
import {
  type HabitSpec, EPOCHE, buildEntry, buildHabit, fixtureHabitId, loadFixtures,
} from "./fixtures.ts";

type Fixture = {
  name: string;
  habit: HabitSpec;
  range: { from: CalendarDate; to: CalendarDate };
  entries: {
    date: CalendarDate; value: number;
    /// Gehört einem anderen Habit — muss draußen bleiben.
    foreign?: boolean;
    deleted?: boolean;
  }[];
  events: {
    date: CalendarDate; at: Timestamp; endsAt?: Timestamp; value: number;
  }[];
  expected: {
    total?: number;
    activeDays?: number;
    dayCount?: number;
    /// Wie überall: Schlüssel fehlt = nicht prüfen, `null` = muss null sein.
    averagePerActiveDay?: number | null;
    byDay?: Record<string, number>;
    byWeek?: Record<string, number>;
    sessionCount?: number;
    sessions?: { date: CalendarDate; count: number; starts?: Timestamp[] };
    events?: {
      date: CalendarDate;
      durationMinutes?: number | null;
      effectiveValue?: number;
      hasValidInterval?: boolean;
    }[];
  };
};

const HABIT_ID = fixtureHabitId(0);
const FREMD_ID = fixtureHabitId(99);

const fixtures = loadFixtures<Fixture>("totals");

test("spec/fixtures/totals liegt am erwarteten Ort und ist nicht leer", () => {
  assert.ok(fixtures.length > 0, "Keine Fixtures gefunden");
});

for (const { file, fixture } of fixtures) {
  test(`${file} — ${fixture.name}`, () => {
    const habit = buildHabit(fixture.habit, HABIT_ID, fixture.name);

    const entries = fixture.entries.map((x, i) => {
      const entry = buildEntry(x.foreign ? FREMD_ID : HABIT_ID, x.date, x.value, i);
      return x.deleted ? { ...entry, deletedAt: EPOCHE } : entry;
    });

    const events: EntryEvent[] = fixture.events.map((x, i) => ({
      id: `event-${i}`, habitId: HABIT_ID, date: x.date,
      at: x.at, endsAt: x.endsAt ?? null, value: x.value,
      source: "manual", createdAt: EPOCHE, updatedAt: EPOCHE,
    }));

    const summe = periodTotal(habit, entries, events, fixture.range.from, fixture.range.to);
    const e = fixture.expected;
    const nah = (a: number, b: number) => Math.abs(a - b) < 1e-9;

    if (e.total !== undefined) assert.ok(nah(summe.total, e.total), `total: ${summe.total}`);
    if (e.activeDays !== undefined) assert.equal(summe.activeDays, e.activeDays, "activeDays");
    if (e.dayCount !== undefined) assert.equal(dayCount(summe), e.dayCount, "dayCount");
    if (e.sessionCount !== undefined) {
      assert.equal(summe.sessionCount, e.sessionCount, "sessionCount");
    }

    if (e.averagePerActiveDay === null) {
      assert.equal(averagePerActiveDay(summe), null, "averagePerActiveDay müsste null sein");
    } else if (e.averagePerActiveDay !== undefined) {
      const schnitt = averagePerActiveDay(summe);
      assert.ok(schnitt != null, "averagePerActiveDay fehlt");
      assert.ok(nah(schnitt, e.averagePerActiveDay),
        `averagePerActiveDay — erwartet ${e.averagePerActiveDay}, war ${schnitt}`);
    }

    for (const [iso, wert] of Object.entries(e.byDay ?? {})) {
      assert.ok(summe.byDay[iso] !== undefined, `byDay ${iso} fehlt`);
      assert.ok(nah(summe.byDay[iso], wert), `byDay ${iso}: ${summe.byDay[iso]}`);
    }
    for (const [iso, wert] of Object.entries(e.byWeek ?? {})) {
      assert.ok(summe.byWeek[iso] !== undefined, `byWeek ${iso} fehlt`);
      assert.ok(nah(summe.byWeek[iso], wert), `byWeek ${iso}: ${summe.byWeek[iso]}`);
    }

    if (e.sessions) {
      const tages = sessions(habit, e.sessions.date, events);
      assert.equal(tages.length, e.sessions.count, "Zahl der Sitzungen");
      if (e.sessions.starts) {
        assert.deepEqual(tages.map((s) => s.at), e.sessions.starts, "Startzeiten sortiert");
      }
    }

    for (const erwartet of e.events ?? []) {
      const event = events.find((x) => x.date === erwartet.date);
      assert.ok(event, `Kein Event am ${erwartet.date}`);
      if (erwartet.durationMinutes === null) {
        assert.equal(durationMinutes(event), null, `${erwartet.date}: durationMinutes`);
      } else if (erwartet.durationMinutes !== undefined) {
        assert.equal(durationMinutes(event), erwartet.durationMinutes,
          `${erwartet.date}: durationMinutes`);
      }
      if (erwartet.effectiveValue !== undefined) {
        assert.equal(effectiveValue(event), erwartet.effectiveValue,
          `${erwartet.date}: effectiveValue`);
      }
      if (erwartet.hasValidInterval !== undefined) {
        assert.equal(hasValidInterval(event), erwartet.hasValidInterval,
          `${erwartet.date}: hasValidInterval`);
      }
    }
  });
}
