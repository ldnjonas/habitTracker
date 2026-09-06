/// Fokus-Läufe und das Freeze-Konto.

import type { FastifyInstance } from "fastify";
import type { Db } from "../db.ts";
import * as store from "../store.ts";
import { datum, pfad, rumpf } from "./helfer.ts";

export function focusRouten(app: FastifyInstance, db: Db): void {
  // **Das Ergebnis wird berechnet, nie gespeichert.** Ob ein Lauf durchgezogen
  // wurde, ergibt sich aus den Einträgen; ein gespeichertes „geschafft" würde
  // von ihnen abdriften, sobald ein Tag nachträglich korrigiert wird.
  app.get("/focus", async () => store.focusProgress(db));

  app.post("/focus", async (anfrage, antwort) => {
    const entwurf = rumpf<{ days?: number; title?: string; habitIds?: string[] }>(anfrage);
    const lauf = store.startFocus(
      db, entwurf.days ?? 7, entwurf.habitIds ?? [], entwurf.title ?? null);
    return antwort.code(201).send(lauf);
  });

  app.delete("/focus/:focusId", async (anfrage, antwort) => {
    const { focusId } = pfad<{ focusId: string }>(anfrage);
    store.deleteFocus(db, focusId);
    return antwort.code(204).send();
  });

  app.post("/focus/:focusId/abandon", async (anfrage) => {
    const { focusId } = pfad<{ focusId: string }>(anfrage);
    return store.abandonFocus(db, focusId);
  });
}

export function freezeRouten(app: FastifyInstance, db: Db): void {
  // Beim Lesen wird eingebucht, was durchgezogene Läufe verdient haben —
  // idempotent über `focusRunId`. Sonst hinkte der Kontostand hinterher, bis
  // jemand zufällig den Fokus-Tab öffnet.
  app.get("/freezes", async () => store.freezeKonto(db));

  app.post("/freezes/apply", async (anfrage, antwort) => {
    const wunsch = rumpf<{ habitId: string; date: string }>(anfrage);
    if (!wunsch.habitId) throw new store.Fehler(400, "habitId ist Pflicht");
    const ausnahme = store.applyFreeze(db, wunsch.habitId, datum(wunsch.date, "date"));
    return antwort.code(201).send(ausnahme);
  });
}
