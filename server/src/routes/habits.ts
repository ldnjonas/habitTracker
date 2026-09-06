/// Habits, ihre Regelversionen und ihre Tags.

import type { FastifyInstance } from "fastify";
import type { Db } from "../db.ts";
import type { HabitRule } from "../domain/schedule.ts";
import * as store from "../store.ts";
import { datum, pfad, rumpf } from "./helfer.ts";

export function habitRouten(app: FastifyInstance, db: Db): void {
  app.get("/habits", async (anfrage) => {
    const abfrage = anfrage.query as { includeArchived?: string; tag?: string };
    return store.listHabits(db, {
      includeArchived: abfrage.includeArchived === "true",
      tag: abfrage.tag,
    });
  });

  app.post("/habits", async (anfrage, antwort) => {
    const habit = store.createHabit(db, rumpf<store.HabitDraft>(anfrage));
    return antwort.code(201).send(habit);
  });

  app.get("/habits/:habitId", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    return store.habitOderFehler(db, habitId);
  });

  app.patch("/habits/:habitId", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    return store.updateHabit(db, habitId, rumpf<Record<string, unknown>>(anfrage));
  });

  app.delete("/habits/:habitId", async (anfrage, antwort) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    store.deleteHabit(db, habitId);
    return antwort.code(204).send();
  });

  // Zeitplan und Ziel gelten ab einem Datum. Genau diese Adressierung trennt
  // „ab heute ändern" von „Tippfehler korrigieren": das eine legt eine Version
  // an, das andere überschreibt eine. Ohne die Unterscheidung würde der Verlauf
  // zum Flickenteppich.
  app.put("/habits/:habitId/rules/:effectiveFrom", async (anfrage) => {
    const p = pfad<{ habitId: string; effectiveFrom: string }>(anfrage);
    const regel = rumpf<HabitRule>(anfrage);
    return store.setRule(db, p.habitId, {
      ...regel,
      effectiveFrom: datum(p.effectiveFrom, "effectiveFrom"),
    });
  });

  app.delete("/habits/:habitId/rules/:effectiveFrom", async (anfrage) => {
    const p = pfad<{ habitId: string; effectiveFrom: string }>(anfrage);
    return store.deleteRule(db, p.habitId, datum(p.effectiveFrom, "effectiveFrom"));
  });

  // Die Menge wird ersetzt, nicht einzeln addiert — das macht den Aufruf
  // idempotent und abgleichstauglich.
  app.put("/habits/:habitId/tags", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    const tagIds = anfrage.body;
    if (!Array.isArray(tagIds)) throw new store.Fehler(400, "Erwartet wird eine Liste von Tag-IDs");
    return store.setTags(db, habitId, tagIds.map(String));
  });
}

export function tagRouten(app: FastifyInstance, db: Db): void {
  app.get("/tags", async () => store.listTags(db));

  app.post("/tags", async (anfrage, antwort) => {
    const entwurf = rumpf<{ name: string; colorHex?: string }>(anfrage);
    return antwort.code(201).send(store.createTag(db, entwurf.name, entwurf.colorHex));
  });

  app.patch("/tags/:tagId", async (anfrage) => {
    const { tagId } = pfad<{ tagId: string }>(anfrage);
    return store.updateTag(db, tagId, rumpf<Record<string, unknown>>(anfrage));
  });

  app.delete("/tags/:tagId", async (anfrage, antwort) => {
    const { tagId } = pfad<{ tagId: string }>(anfrage);
    store.deleteTag(db, tagId);
    return antwort.code(204).send();
  });
}
