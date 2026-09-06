import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Db } from "./db.ts";
import { pruefeToken } from "./auth.ts";
import { leseDelta, schreibeDelta, type Delta } from "./sync.ts";
import { Fehler } from "./store.ts";
import { habitRouten, tagRouten } from "./routes/habits.ts";
import { entryRouten, journalRouten, papierkorbRouten } from "./routes/entries.ts";
import { focusRouten, freezeRouten } from "./routes/focus.ts";
import { insightRouten } from "./routes/insights.ts";
import { backupRouten } from "./routes/backup.ts";

/// Der Server, ohne zu wissen, wo er läuft.
///
/// **Hier steht nichts von Node und nichts von Deno.** Hono spricht die
/// Web-Standards `Request` und `Response`; darüber liegt in `index.ts` der
/// Node-Betrieb und in `supabase/functions/api/` die Edge Function. Dieselben
/// Routen, derselbe Zugangsschutz, dieselben Tests — nur ein anderer Wirt.
export function baueApp(db: Db, token: string, herkuenfte: string[] = []): Hono {
  const app = new Hono();

  // Ein Fehler des Aufrufers ist keine 500. Ohne diese Unterscheidung räumte
  // der Server jeden Fehler als seinen eigenen ein, und in den Protokollen
  // stünde ein Stapelabzug statt einer Erklärung.
  app.onError((fehler, c) => {
    if (fehler instanceof Fehler) {
      return c.json({
        error: fehler.message,
        ...(fehler.details ? { problems: fehler.details } : {}),
      }, fehler.statusCode as 400);
    }
    console.error(fehler);
    return c.json({ error: fehler.message }, 500);
  });

  // Nur nötig, wenn die WebApp woanders liegt als die API — bei Cloudflare
  // Pages tut sie das. Läuft beides unter einer Adresse, bleibt die Liste leer
  // und es gibt keine Vorabfrage.
  if (herkuenfte.length > 0) {
    app.use("/*", cors({
      origin: herkuenfte,
      allowHeaders: ["authorization", "content-type"],
      allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
      maxAge: 86400,
    }));
  }

  // Ohne Schutz erreichbar: sonst müsste eine Überwachung das Token kennen.
  //
  // `instance` sagt, **welche** Datenbank hier antwortet. Ein Client vergleicht
  // sie mit der, gegen die er zuletzt abgeglichen hat: stimmt sie nicht oder
  // steht die Sequenz niedriger als sein Cursor, redet er mit einer anderen
  // oder zurückgesetzten Datenbank und muss von vorn anfangen. Die Kennung ist
  // eine Zufallszahl und verrät nichts.
  app.get("/health", async (c) => c.json({
    ok: true,
    seq: await db.aktuelleSequenz(),
    instance: await db.instanz(),
  }));

  const geschuetzt = new Hono();
  geschuetzt.use("/*", pruefeToken(token));

  geschuetzt.get("/sync", async (c) => {
    const since = Number(c.req.query("since") ?? 0);
    const limit = Math.min(Number(c.req.query("limit") ?? 500), 2000);
    if (!Number.isFinite(since) || since < 0) {
      throw new Fehler(400, "since muss eine Zahl ≥ 0 sein");
    }
    return c.json(await leseDelta(db, since, limit));
  });

  // Antwortet nur mit dem Bericht, nicht mit einem Delta.
  //
  // Die autoritativen Werte — gestutzte Zeitstempel, vergebene
  // Sequenznummern — holt der Client mit dem folgenden `GET` ohnehin ab: die
  // gerade geschriebenen Zeilen liegen dann über seinem Cursor. Sie hier
  // zusätzlich mitzuschicken wäre eine zweite Fassung derselben Wahrheit.
  geschuetzt.post("/sync", async (c) => {
    const delta = await c.req.json().catch(() => ({})) as Delta;
    return c.json(await schreibeDelta(db, delta ?? {}));
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

  app.route("/", geschuetzt);
  return app;
}
