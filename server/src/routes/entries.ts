/// Tageswerte und ihr Zeitstempel-Detail.

import type { FastifyInstance } from "fastify";
import type { Db } from "../db.ts";
import * as store from "../store.ts";
import { datum, pfad, rumpf, zeitraum } from "./helfer.ts";

export function entryRouten(app: FastifyInstance, db: Db): void {
  app.get("/entries", async (anfrage) => {
    const { from, to } = zeitraum(anfrage);
    return await store.listEntries(db, from, to);
  });

  app.get("/habits/:habitId/entries", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    const { from, to } = zeitraum(anfrage);
    return await store.listEntries(db, from, to, habitId);
  });

  // Der zentrale Schreibvorgang der App. Idempotent, weil über `(habitId,
  // date)` adressiert — ein nach Verbindungsabbruch doppelt gesendeter Aufruf
  // ist unschädlich.
  app.put("/habits/:habitId/entries/:date", async (anfrage) => {
    const p = pfad<{ habitId: string; date: string }>(anfrage);
    const wert = rumpf<{ value: number; note?: string | null; source?: string }>(anfrage);
    return await store.upsertEntry(db, p.habitId, datum(p.date, "date"), wert);
  });

  app.delete("/habits/:habitId/entries/:date", async (anfrage, antwort) => {
    const p = pfad<{ habitId: string; date: string }>(anfrage);
    await store.deleteEntry(db, p.habitId, datum(p.date, "date"));
    return antwort.code(204).send();
  });

  // Sitzungen. Die Streak-Engine liest sie **nie** — sie arbeitet ausschließlich
  // auf `entry.value`. Dadurch bleibt der Tages-Upsert idempotent.
  app.get("/habits/:habitId/events", async (anfrage) => {
    const { habitId } = pfad<{ habitId: string }>(anfrage);
    const { from, to } = zeitraum(anfrage);
    return await store.listEvents(db, habitId, from, to);
  });

  app.put("/habits/:habitId/events/:eventId", async (anfrage) => {
    const p = pfad<{ habitId: string; eventId: string }>(anfrage);
    return await store.upsertEvent(db, p.habitId, p.eventId, rumpf<Record<string, unknown>>(anfrage));
  });

  app.delete("/habits/:habitId/events/:eventId", async (anfrage, antwort) => {
    const p = pfad<{ habitId: string; eventId: string }>(anfrage);
    await store.deleteEvent(db, p.habitId, p.eventId);
    return antwort.code(204).send();
  });
}

export function journalRouten(app: FastifyInstance, db: Db): void {
  app.get("/days", async (anfrage) => {
    const { from, to } = zeitraum(anfrage);
    return await store.listDayLogs(db, from, to);
  });

  app.get("/days/:date", async (anfrage) => {
    const { date } = pfad<{ date: string }>(anfrage);
    const log = await store.dayLog(db, datum(date, "date"));
    if (!log) throw store.nichtGefunden(`Journaleintrag vom ${date}`);
    return log;
  });

  app.put("/days/:date", async (anfrage) => {
    const { date } = pfad<{ date: string }>(anfrage);
    return await store.upsertDayLog(db, datum(date, "date"), rumpf<Record<string, unknown>>(anfrage));
  });

  app.get("/exceptions", async (anfrage) => {
    const { from, to } = zeitraum(anfrage);
    return await store.listExceptions(db, from, to);
  });

  app.post("/exceptions", async (anfrage, antwort) => {
    const ausnahme = await store.createException(db, rumpf<Record<string, unknown>>(anfrage));
    return antwort.code(201).send(ausnahme);
  });

  app.delete("/exceptions/:exceptionId", async (anfrage, antwort) => {
    const { exceptionId } = pfad<{ exceptionId: string }>(anfrage);
    await store.deleteException(db, exceptionId);
    return antwort.code(204).send();
  });
}

export function papierkorbRouten(app: FastifyInstance, db: Db): void {
  app.get("/trash", async () => await store.trash(db));

  app.post("/trash/restore", async (anfrage, antwort) => {
    const item = rumpf<{ table: string; rowId: string }>(anfrage);
    if (!item.table || !item.rowId) {
      throw new store.Fehler(400, "table und rowId sind Pflicht");
    }
    await store.restore(db, item);
    return antwort.code(204).send();
  });
}
