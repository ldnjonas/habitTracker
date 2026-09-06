/// Habits, ihre Regelversionen und ihre Tags.

import type { Hono } from "hono";
import type { Db } from "../db.ts";
import type { HabitRule } from "../domain/schedule.ts";
import * as store from "../store.ts";
import { datum, pfad, rumpf } from "./helfer.ts";

export function habitRouten(app: Hono, db: Db): void {
  app.get("/habits", async (c) => {
    return c.json(await store.listHabits(db, {
      includeArchived: c.req.query("includeArchived") === "true",
      tag: c.req.query("tag"),
    }));
  });

  app.post("/habits", async (c) => {
    return c.json(await store.createHabit(db, await rumpf<store.HabitDraft>(c)), 201);
  });

  app.get("/habits/:habitId", async (c) => {
    const { habitId } = pfad<{ habitId: string }>(c);
    return c.json(await store.habitOderFehler(db, habitId));
  });

  app.patch("/habits/:habitId", async (c) => {
    const { habitId } = pfad<{ habitId: string }>(c);
    return c.json(await store.updateHabit(db, habitId, await rumpf<Record<string, unknown>>(c)));
  });

  app.delete("/habits/:habitId", async (c) => {
    const { habitId } = pfad<{ habitId: string }>(c);
    await store.deleteHabit(db, habitId);
    return c.body(null, 204);
  });

  // Zeitplan und Ziel gelten ab einem Datum. Genau diese Adressierung trennt
  // „ab heute ändern" von „Tippfehler korrigieren": das eine legt eine Version
  // an, das andere überschreibt eine. Ohne die Unterscheidung würde der Verlauf
  // zum Flickenteppich.
  app.put("/habits/:habitId/rules/:effectiveFrom", async (c) => {
    const p = pfad<{ habitId: string; effectiveFrom: string }>(c);
    const regel = await rumpf<HabitRule>(c);
    return c.json(await store.setRule(db, p.habitId, {
      ...regel,
      effectiveFrom: datum(p.effectiveFrom, "effectiveFrom"),
    }));
  });

  app.delete("/habits/:habitId/rules/:effectiveFrom", async (c) => {
    const p = pfad<{ habitId: string; effectiveFrom: string }>(c);
    return c.json(await store.deleteRule(db, p.habitId, datum(p.effectiveFrom, "effectiveFrom")));
  });

  // Die Menge wird ersetzt, nicht einzeln addiert — das macht den Aufruf
  // idempotent und abgleichstauglich.
  app.put("/habits/:habitId/tags", async (c) => {
    const { habitId } = pfad<{ habitId: string }>(c);
    const tagIds = await c.req.json().catch(() => null);
    if (!Array.isArray(tagIds)) throw new store.Fehler(400, "Erwartet wird eine Liste von Tag-IDs");
    return c.json(await store.setTags(db, habitId, tagIds.map(String)));
  });
}

export function tagRouten(app: Hono, db: Db): void {
  app.get("/tags", async (c) => c.json(await store.listTags(db)));

  app.post("/tags", async (c) => {
    const entwurf = await rumpf<{ name: string; colorHex?: string }>(c);
    return c.json(await store.createTag(db, entwurf.name, entwurf.colorHex), 201);
  });

  app.patch("/tags/:tagId", async (c) => {
    const { tagId } = pfad<{ tagId: string }>(c);
    return c.json(await store.updateTag(db, tagId, await rumpf<Record<string, unknown>>(c)));
  });

  app.delete("/tags/:tagId", async (c) => {
    const { tagId } = pfad<{ tagId: string }>(c);
    await store.deleteTag(db, tagId);
    return c.body(null, 204);
  });
}
