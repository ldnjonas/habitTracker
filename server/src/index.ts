import Fastify from "fastify";
import { Db } from "./db.ts";
import { leseToken, pruefeToken } from "./auth.ts";
import { leseDelta, schreibeDelta, type Delta } from "./sync.ts";

export function baueServer(db: Db, token: string) {
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? "info" } });

  // Ohne Schutz erreichbar: sonst müsste eine Überwachung das Token kennen.
  app.get("/health", async () => ({ ok: true, seq: db.aktuelleSequenz() }));

  app.register(async (geschuetzt) => {
    geschuetzt.addHook("onRequest", pruefeToken(token));

    geschuetzt.get("/sync", async (anfrage) => {
      const abfrage = anfrage.query as { since?: string; limit?: string };
      const since = Number(abfrage.since ?? 0);
      const limit = Math.min(Number(abfrage.limit ?? 500), 2000);
      if (!Number.isFinite(since) || since < 0) {
        throw app.httpErrors?.badRequest?.("since muss eine Zahl ≥ 0 sein")
          ?? new Error("since muss eine Zahl ≥ 0 sein");
      }
      return leseDelta(db, since, limit);
    });

    geschuetzt.post("/sync", async (anfrage) => {
      const delta = anfrage.body as Delta;
      const bericht = schreibeDelta(db, delta ?? {});
      // Der Client bekommt zurück, was der Server daraus gemacht hat — mit
      // seinen Zeitstempeln und Sequenznummern. Er übernimmt diese Fassung,
      // statt seiner eigenen zu vertrauen.
      return { ...bericht, ...leseDelta(db, bericht.nextSeq - bericht.angenommen) };
    });
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
