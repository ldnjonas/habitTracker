/// Tageswerte und ihr Zeitstempel-Detail.

import type { Hono } from "hono";
import type { Db } from "../db.ts";
import * as store from "../store.ts";
import { datum, pfad, rumpf, zeitraum } from "./helfer.ts";

export function entryRouten(app: Hono, db: Db): void {
  app.get("/entries", async (c) => {
    const { from, to } = zeitraum(c);
    return c.json(await store.listEntries(db, from, to));
  });

  app.get("/habits/:habitId/entries", async (c) => {
    const { habitId } = pfad<{ habitId: string }>(c);
    const { from, to } = zeitraum(c);
    return c.json(await store.listEntries(db, from, to, habitId));
  });

  // Der zentrale Schreibvorgang der App. Idempotent, weil über `(habitId,
  // date)` adressiert — ein nach Verbindungsabbruch doppelt gesendeter Aufruf
  // ist unschädlich.
  app.put("/habits/:habitId/entries/:date", async (c) => {
    const p = pfad<{ habitId: string; date: string }>(c);
    const wert = await rumpf<{ value: number; note?: string | null; source?: string }>(c);
    return c.json(await store.upsertEntry(db, p.habitId, datum(p.date, "date"), wert));
  });

  app.delete("/habits/:habitId/entries/:date", async (c) => {
    const p = pfad<{ habitId: string; date: string }>(c);
    await store.deleteEntry(db, p.habitId, datum(p.date, "date"));
    return c.body(null, 204);
  });

  // Sitzungen. Die Streak-Engine liest sie **nie** — sie arbeitet ausschließlich
  // auf `entry.value`. Dadurch bleibt der Tages-Upsert idempotent.
  app.get("/habits/:habitId/events", async (c) => {
    const { habitId } = pfad<{ habitId: string }>(c);
    const { from, to } = zeitraum(c);
    return c.json(await store.listEvents(db, habitId, from, to));
  });

  app.put("/habits/:habitId/events/:eventId", async (c) => {
    const p = pfad<{ habitId: string; eventId: string }>(c);
    return c.json(await store.upsertEvent(
      db, p.habitId, p.eventId, await rumpf<Record<string, unknown>>(c)));
  });

  app.delete("/habits/:habitId/events/:eventId", async (c) => {
    const p = pfad<{ habitId: string; eventId: string }>(c);
    await store.deleteEvent(db, p.habitId, p.eventId);
    return c.body(null, 204);
  });
}

export function journalRouten(app: Hono, db: Db): void {
  app.get("/days", async (c) => {
    const { from, to } = zeitraum(c);
    return c.json(await store.listDayLogs(db, from, to));
  });

  app.get("/days/:date", async (c) => {
    const { date } = pfad<{ date: string }>(c);
    const log = await store.dayLog(db, datum(date, "date"));
    if (!log) throw store.nichtGefunden(`Journaleintrag vom ${date}`);
    return c.json(log);
  });

  app.put("/days/:date", async (c) => {
    const { date } = pfad<{ date: string }>(c);
    return c.json(await store.upsertDayLog(
      db, datum(date, "date"), await rumpf<Record<string, unknown>>(c)));
  });

  app.get("/exceptions", async (c) => {
    const { from, to } = zeitraum(c);
    return c.json(await store.listExceptions(db, from, to));
  });

  app.post("/exceptions", async (c) => {
    const ausnahme = await store.createException(db, await rumpf<Record<string, unknown>>(c));
    return c.json(ausnahme, 201);
  });

  app.delete("/exceptions/:exceptionId", async (c) => {
    const { exceptionId } = pfad<{ exceptionId: string }>(c);
    await store.deleteException(db, exceptionId);
    return c.body(null, 204);
  });
}

export function papierkorbRouten(app: Hono, db: Db): void {
  app.get("/trash", async (c) => c.json(await store.trash(db)));

  app.post("/trash/restore", async (c) => {
    const item = await rumpf<{ table: string; rowId: string }>(c);
    if (!item.table || !item.rowId) {
      throw new store.Fehler(400, "table und rowId sind Pflicht");
    }
    await store.restore(db, item);
    return c.body(null, 204);
  });
}
