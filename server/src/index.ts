import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Db } from "./db.ts";
import { leseToken } from "./auth.ts";
import { baueApp } from "./app.ts";

/// Der Betrieb unter Node — für die Entwicklung und für den Server zu Hause.
///
/// Die Edge Function bei Supabase startet dieselbe App aus `app.ts`, nur ohne
/// diese Datei: dort gibt es kein Dateisystem, das eine WebApp ausliefern
/// könnte, und keinen Port, auf den man lauschen müsste.

/// Wo die gebaute WebApp liegt: `web/dist`, eine Ebene über `server/`.
const WEB = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "web", "dist");

const token = leseToken();
// `DATABASE_URL` zeigt auf ein entferntes Postgres, `HABIT_DB` auf einen
// Ordner für das eingebettete.
//
// Der Rückfall ist ein **Ordner** und nicht der Arbeitsspeicher. Ein Server,
// der nach einem Neustart mit leerem Bestand und frisch gewürfelter Kennung
// dasteht, ist schlimmer als einer, der gar nicht startet: die Clients
// erkennen eine fremde Datenbank und werfen ihren eigenen Stand weg.
const db = await Db.oeffne(process.env.DATABASE_URL ?? process.env.HABIT_DB ?? "./pgdaten");

const herkuenfte = (process.env.HABIT_ORIGINS ?? "")
  .split(",").map((s) => s.trim()).filter(Boolean);

// **Reihenfolge ist hier alles.** Die WebApp wird zuerst eingehängt, die API
// danach: Hono arbeitet die Einträge in der Reihenfolge ab, in der sie
// registriert wurden. Umgekehrt läge der Zugangsschutz der API über den
// Dateien, und der Browser bekäme eine 401 statt des Anmeldefeldes — Fastify
// kapselte seine Middleware im Plugin, Hono tut das nicht.
const app = new Hono();
liefereWebApp(app);
app.route("/", baueApp(db, token, herkuenfte));

const port = Number(process.env.PORT ?? 8080);
const sequenz = await db.aktuelleSequenz();
serve({ fetch: app.fetch, port, hostname: "0.0.0.0" });
console.log(`Abgleich-Server auf Port ${port}, Sequenz ${sequenz}`);

/// Liefert die gebaute WebApp aus — ein Ursprung, eine Adresse, kein CORS.
///
/// **Ohne Token.** Was hier ausgeliefert wird, sind Gerüst und Programmtext und
/// keine Daten; die holt die Oberfläche selbst, und dafür braucht sie das
/// Token. Ein Schutz auf den Dateien würde nur verhindern, dass man das
/// Anmeldefeld überhaupt zu sehen bekommt.
///
/// Ist nichts gebaut, bleibt es beim reinen API-Server.
function liefereWebApp(app: Hono): void {
  if (!existsSync(join(WEB, "index.html"))) {
    console.warn(`Keine gebaute WebApp unter ${WEB} — nur die API ist erreichbar.`);
    return;
  }

  // Als Middleware und nicht als Endpunkt: was hier keine Datei ist, muss
  // weitergereicht werden, sonst verdeckte die WebApp die ganze API.
  app.use("/*", async (c, next) => {
    if (c.req.method !== "GET") return await next();
    const pfad = decodeURIComponent(new URL(c.req.url).pathname);
    if (pfad.includes("..")) return await next();

    const datei = join(WEB, pfad);
    if (pfad !== "/" && istDatei(datei)) {
      return c.body(readFileSync(datei), 200, { "content-type": typFuer(datei) });
    }

    // Die Wurzel ist immer die App — auch für einen Aufrufer ohne
    // `Accept`-Kopf. Sonst antwortete `curl /` mit einer 401, und man suchte
    // den Fehler beim Zugangsschutz statt bei der Auslieferung.
    if (pfad === "/") return c.html(readFileSync(join(WEB, "index.html"), "utf8"));

    // Eine Einzelseiten-App hat nur eine Seite: jeder Pfad, den niemand kennt,
    // ist ein Aufruf ihres eigenen Wegs und keine fehlende Datei. Nur für
    // Browser-Anfragen — ein API-Aufruf ins Leere darf kein HTML bekommen,
    // sonst suchte ein Klient den Fehler im Falschen.
    if ((c.req.header("accept") ?? "").includes("text/html")) {
      return c.html(readFileSync(join(WEB, "index.html"), "utf8"));
    }

    await next();
  });
}

/// Eine Datei, kein Verzeichnis — `existsSync` sagt auch bei `/` ja, und dann
/// bekäme die Wurzel der WebApp einen Verzeichniseintrag statt ihrer Seite.
function istDatei(pfad: string): boolean {
  return statSync(pfad, { throwIfNoEntry: false })?.isFile() ?? false;
}

const TYPEN: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

function typFuer(datei: string): string {
  const punkt = datei.lastIndexOf(".");
  return TYPEN[datei.slice(punkt)] ?? "application/octet-stream";
}
