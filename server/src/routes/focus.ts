/// Fokus-Läufe und das Freeze-Konto.

import type { Hono } from "hono";
import type { Db } from "../db.ts";
import * as store from "../store.ts";
import { datum, pfad, rumpf } from "./helfer.ts";

export function focusRouten(app: Hono, db: Db): void {
  // **Das Ergebnis wird berechnet, nie gespeichert.** Ob ein Lauf durchgezogen
  // wurde, ergibt sich aus den Einträgen; ein gespeichertes „geschafft" würde
  // von ihnen abdriften, sobald ein Tag nachträglich korrigiert wird.
  app.get("/focus", async (c) => c.json(await store.focusProgress(db)));

  app.post("/focus", async (c) => {
    const entwurf = await rumpf<{ days?: number; title?: string; habitIds?: string[] }>(c);
    const lauf = await store.startFocus(
      db, entwurf.days ?? 7, entwurf.habitIds ?? [], entwurf.title ?? null);
    return c.json(lauf, 201);
  });

  app.delete("/focus/:focusId", async (c) => {
    const { focusId } = pfad<{ focusId: string }>(c);
    await store.deleteFocus(db, focusId);
    return c.body(null, 204);
  });

  app.post("/focus/:focusId/abandon", async (c) => {
    const { focusId } = pfad<{ focusId: string }>(c);
    return c.json(await store.abandonFocus(db, focusId));
  });
}

export function freezeRouten(app: Hono, db: Db): void {
  // Beim Lesen wird eingebucht, was durchgezogene Läufe verdient haben —
  // idempotent über `focusRunId`. Sonst hinkte der Kontostand hinterher, bis
  // jemand zufällig den Fokus-Tab öffnet.
  app.get("/freezes", async (c) => c.json(await store.freezeKonto(db)));

  app.post("/freezes/apply", async (c) => {
    const wunsch = await rumpf<{ habitId: string; date: string }>(c);
    if (!wunsch.habitId) throw new store.Fehler(400, "habitId ist Pflicht");
    const ausnahme = await store.applyFreeze(db, wunsch.habitId, datum(wunsch.date, "date"));
    return c.json(ausnahme, 201);
  });
}
