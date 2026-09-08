import { Hono } from "hono";
import { Db } from "../../../server/src/db.ts";
import { baueApp } from "../../../server/src/app.ts";
import { leseToken } from "../../../server/src/auth.ts";
import { umgebung } from "../../../server/src/umgebung.ts";

/// Der Server als Edge Function.
///
/// Alles Fachliche steht in `server/src/` und weiß nicht, wo es läuft. Hier
/// steht nur, was Deno von Node unterscheidet: woher die Verbindung kommt und
/// wer auf Anfragen hört.
///
/// **`verify_jwt = false`** in `config.toml` — sonst prüfte Supabases eigenes
/// Tor ein JWT, und unser `Authorization: Bearer <Token>` käme nie an. Damit
/// ist das Token der einzige Schutz; es gehört lang und zufällig.

const url = umgebung("HABIT_DATABASE_URL") ?? umgebung("SUPABASE_DB_URL");
if (!url) throw new Error("HABIT_DATABASE_URL fehlt");
const token = leseToken();
const herkuenfte = (umgebung("HABIT_ORIGINS") ?? "")
  .split(",").map((s) => s.trim()).filter(Boolean);

/// **Supabase reicht den Pfad mit Vorsatz durch**, und welcher es ist, hängt
/// vom Weg ab: über die öffentliche Adresse kommt `/functions/v1/api/health`
/// an, im lokalen Betrieb `/api/health`. Ohne passenden Vorsatz greift keine
/// Route — und die einzige Zeile, die dann noch zieht, ist der Zugangsschutz.
/// Erst antwortete deshalb selbst `/health` mit 401, danach mit 404.
///
/// Statt zu raten wird die App unter allen dreien eingehängt. Sie ist dieselbe;
/// es kostet nichts außer drei Einträgen in der Wegetabelle.
const VORSAETZE = ["/functions/v1/api", "/api", "/"];

Deno.serve(async (anfrage: Request) => {
  // **Eine Verbindung je Anfrage.** Eine über die Lebenszeit der Funktion wäre
  // billiger, aber `BEGIN` und `COMMIT` gälten dann für alles, was gerade
  // gleichzeitig läuft — die WebApp lädt beim Öffnen mehrere Endpunkte auf
  // einmal, und eine fremde Abfrage geriete mitten in eine fremde Transaktion.
  //
  // Teuer ist das nicht: die Adresse zeigt auf Supavisor, den Verbindungspool
  // von Supabase. Dort ist eine Verbindung ein Eintrag in einer Liste und kein
  // neuer Prozess.
  const db = Db.oeffne(url);
  try {
    const innen = baueApp(db, token, herkuenfte);
    const aussen = new Hono();
    for (const vorsatz of VORSAETZE) aussen.route(vorsatz, innen);
    return await aussen.fetch(anfrage);
  } finally {
    await db.schliesse();
  }
});
