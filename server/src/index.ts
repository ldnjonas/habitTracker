import Fastify, { type FastifyError } from "fastify";
import { Db } from "./db.ts";
import { leseToken, pruefeToken } from "./auth.ts";
import { leseDelta, schreibeDelta, type Delta } from "./sync.ts";
import { Fehler } from "./store.ts";
import { habitRouten, tagRouten } from "./routes/habits.ts";
import { entryRouten, journalRouten, papierkorbRouten } from "./routes/entries.ts";
import { focusRouten, freezeRouten } from "./routes/focus.ts";
import { insightRouten } from "./routes/insights.ts";
import { backupRouten } from "./routes/backup.ts";

export function baueServer(db: Db, token: string) {
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? "info" } });

  // Ein Fehler des Aufrufers ist keine 500. Ohne diese Unterscheidung räumte
  // der Server jeden Fehler als seinen eigenen ein, und in den Protokollen
  // stünde ein Stapelabzug statt einer Erklärung.
  app.setErrorHandler((fehler: FastifyError, _anfrage, antwort) => {
    if (fehler instanceof Fehler) {
      return antwort.code(fehler.statusCode).send({
        error: fehler.message,
        ...(fehler.details ? { problems: fehler.details } : {}),
      });
    }
    const status = fehler.statusCode ?? 500;
    if (status >= 500) app.log.error(fehler);
    return antwort.code(status).send({ error: fehler.message });
  });

  // Ohne Schutz erreichbar: sonst müsste eine Überwachung das Token kennen.
  app.get("/health", async () => ({ ok: true, seq: db.aktuelleSequenz() }));

  app.register(async (geschuetzt) => {
    geschuetzt.addHook("onRequest", pruefeToken(token));

    geschuetzt.get("/sync", async (anfrage) => {
      const abfrage = anfrage.query as { since?: string; limit?: string };
      const since = Number(abfrage.since ?? 0);
      const limit = Math.min(Number(abfrage.limit ?? 500), 2000);
      if (!Number.isFinite(since) || since < 0) {
        throw new Fehler(400, "since muss eine Zahl ≥ 0 sein");
      }
      return leseDelta(db, since, limit);
    });

    // Antwortet nur mit dem Bericht, nicht mit einem Delta.
    //
    // Die autoritativen Werte — gestutzte Zeitstempel, vergebene
    // Sequenznummern — holt der Client mit dem folgenden `GET` ohnehin ab: die
    // gerade geschriebenen Zeilen liegen dann über seinem Cursor. Sie hier
    // zusätzlich mitzuschicken wäre eine zweite Fassung derselben Wahrheit.
    geschuetzt.post("/sync", async (anfrage) => {
      const delta = anfrage.body as Delta;
      return schreibeDelta(db, delta ?? {});
    });

    // Die Ressourcen für die WebApp. Sie schreiben in dieselben Tabellen wie
    // der Abgleich und vergeben dieselben Sequenznummern — sonst sähe der Mac
    // nichts von dem, was im Browser passiert.
    habitRouten(geschuetzt, db);
    tagRouten(geschuetzt, db);
    entryRouten(geschuetzt, db);
    journalRouten(geschuetzt, db);
    papierkorbRouten(geschuetzt, db);
    focusRouten(geschuetzt, db);
    freezeRouten(geschuetzt, db);
    insightRouten(geschuetzt, db);
    backupRouten(geschuetzt, db);
  });

  return app;
}

// Nur starten, wenn direkt aufgerufen — bei einem Import aus den Tests nicht.
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop()!)) {
  const token = leseToken();
  const db = new Db(process.env.HABIT_DB ?? "habits.sqlite");
  const app = baueServer(db, token);
  const port = Number(process.env.PORT ?? 8080);
  app.listen({ port, host: "0.0.0.0" })
    .then(() => app.log.info(`Abgleich-Server auf Port ${port}, Sequenz ${db.aktuelleSequenz()}`))
    .catch((fehler) => { app.log.error(fehler); process.exit(1); });
}
