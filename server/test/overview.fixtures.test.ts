/// Die Übersichts-Fixtures, gerechnet von der TypeScript-Domäne.
///
/// Das Gegenstück zu `OverviewFixtureTests.swift`.

import { test } from "node:test";
import assert from "node:assert/strict";

import type { CalendarDate } from "../src/domain/calendar.ts";
import { requireDate } from "../src/domain/calendar.ts";
import type { ExceptionKind } from "../src/domain/entry.ts";
import {
  type DaySummary, type IntensityScale, type OverviewSpan,
  intensityLevel, isPerfect, overview, overviewStats,
  share, spanMaximumDays, spanRange, spanShift,
} from "../src/domain/overview.ts";
import {
  type HabitSpec, buildEntry, buildException, buildHabits, loadFixtures,
} from "./fixtures.ts";

type Fixture = {
  name: string;
  today: CalendarDate;
  range: { from: CalendarDate; to: CalendarDate };
  habits: HabitSpec[];
  entries: { habit: string; date: CalendarDate; value: number }[];
  /// `habit: null` heißt: gilt für alle (Urlaub).
  exceptions: { habit: string | null; date: CalendarDate; kind: ExceptionKind }[];
  expected: {
    /// Nur die aufgeführten Tage werden geprüft, nicht der ganze Zeitraum.
    days?: Record<string, {
      completed?: number;
      scheduled?: number;
      /// Wie überall: Schlüssel fehlt = nicht prüfen, `null` = muss null sein.
      share?: number | null;
      isPerfect?: boolean;
    }>;
    stats?: {
      perfectDays?: number;
      daysWithPlan?: number;
      totalCompletions?: number;
      perfectStreak?: number;
      busiestDay?: number;
    };
    /// Farbstufe für einen Tag aus `days`.
    intensity?: { date: CalendarDate; scale: IntensityScale; busiestDay: number; level: number }[];
    /// Farbstufe für eine frei gesetzte Tagesbilanz — ohne Habits.
    levels?: {
      completed: number; scheduled: number;
      scale: IntensityScale; busiestDay: number; level: number;
    }[];
    spans?: {
      span: OverviewSpan;
      anchor: CalendarDate;
      range?: { from: CalendarDate; to: CalendarDate };
      shiftBy?: number;
      shifted?: CalendarDate;
      maximumDays?: number;
    }[];
  };
};

const fixtures = loadFixtures<Fixture>("overview");

test("spec/fixtures/overview liegt am erwarteten Ort und ist nicht leer", () => {
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
      (e, i) => buildEntry(habitId(e.habit), e.date, e.value, i));
    const exceptions = fixture.exceptions.map(
      (x, i) => buildException(x.habit == null ? null : habitId(x.habit), x.date, x.kind, i));

    const summaries = overview(
      habits, entries, exceptions, fixture.range.from, fixture.range.to, fixture.today);
    const e = fixture.expected;

    for (const [iso, erwartet] of Object.entries(e.days ?? {})) {
      const summary = summaries[requireDate(iso)];
      assert.ok(summary, `${iso} fehlt im Zeitraum`);
      if (erwartet.completed !== undefined) {
        assert.equal(summary.completed, erwartet.completed, `${iso}: completed`);
      }
      if (erwartet.scheduled !== undefined) {
        assert.equal(summary.scheduled, erwartet.scheduled, `${iso}: scheduled`);
      }
      if (erwartet.isPerfect !== undefined) {
        assert.equal(isPerfect(summary), erwartet.isPerfect, `${iso}: isPerfect`);
      }
      if (erwartet.share === null) {
        assert.equal(share(summary), null, `${iso}: share müsste null sein`);
      } else if (erwartet.share !== undefined) {
        const anteil = share(summary);
        assert.ok(anteil != null, `${iso}: share fehlt`);
        assert.ok(Math.abs(anteil - erwartet.share) < 1e-9,
          `${iso}: share — erwartet ${erwartet.share}, war ${anteil}`);
      }
    }

    if (e.stats) {
      const kennzahlen = overviewStats(
        summaries, fixture.range.from, fixture.range.to, fixture.today);
      for (const [feld, erwartet] of Object.entries(e.stats)) {
        assert.equal(kennzahlen[feld as keyof typeof kennzahlen], erwartet, feld);
      }
    }

    for (const fall of e.intensity ?? []) {
      const summary = summaries[fall.date];
      assert.ok(summary, `${fall.date} fehlt im Zeitraum`);
      assert.equal(intensityLevel(summary, fall.scale, fall.busiestDay), fall.level,
        `Farbstufe ${fall.date} nach ${fall.scale}`);
    }

    for (const fall of e.levels ?? []) {
      const summary: DaySummary = {
        date: fixture.today, completed: fall.completed, scheduled: fall.scheduled,
      };
      assert.equal(intensityLevel(summary, fall.scale, fall.busiestDay), fall.level,
        `Farbstufe ${fall.completed}/${fall.scheduled} nach ${fall.scale}` +
        ` bei busiestDay ${fall.busiestDay}`);
    }

    for (const fall of e.spans ?? []) {
      if (fall.range) {
        const bereich = spanRange(fall.span, fall.anchor);
        assert.equal(bereich.from, fall.range.from, `${fall.span} ab ${fall.anchor}: from`);
        assert.equal(bereich.to, fall.range.to, `${fall.span} ab ${fall.anchor}: to`);
      }
      if (fall.shifted !== undefined) {
        assert.ok(fall.shiftBy !== undefined, "shifted ohne shiftBy");
        assert.equal(spanShift(fall.span, fall.anchor, fall.shiftBy), fall.shifted,
          `${fall.span} ${fall.anchor} um ${fall.shiftBy}`);
      }
      if (fall.maximumDays !== undefined) {
        assert.equal(spanMaximumDays(fall.span), fall.maximumDays, `${fall.span}: maximumDays`);
      }
    }
  });
}
