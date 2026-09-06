import type { Context, Next } from "hono";

/// Zugangsschutz, v1: ein statisches Token aus der Umgebung.
///
/// Kein Login-Flow, weil die App zunächst nur privat läuft. Das Fundament für
/// später steht trotzdem: `user_id` liegt in jeder Tabelle, der Header ist
/// schon `Authorization: Bearer`, und ein echtes JWT ersetzt später nur die
/// Prüfung in dieser Datei.
export function leseToken(umgebung: Record<string, string | undefined> = process.env): string {
  const token = umgebung.HABIT_TOKEN?.trim();
  if (!token || token.length < 16) {
    // Bewusst abbrechen statt ungeschützt zu starten. Ein Abgleich-Server ohne
    // Schutz im Netz gibt den kompletten Verlauf preis, und ein Server, der
    // „läuft", fällt niemandem als Problem auf.
    throw new Error(
      "HABIT_TOKEN fehlt oder ist zu kurz (mindestens 16 Zeichen).\n" +
      "Eins erzeugen:  openssl rand -base64 32");
  }
  return token;
}

/// Vergleich in gleichbleibender Zeit.
///
/// Ein Vergleich, der beim ersten falschen Zeichen abbricht, verrät über die
/// Antwortzeit, wie weit man richtig lag.
function gleich(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let unterschied = 0;
  for (let i = 0; i < a.length; i++) unterschied |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return unterschied === 0;
}

export function pruefeToken(token: string) {
  return async (c: Context, next: Next) => {
    const kopf = c.req.header("authorization") ?? "";
    const mitgeschickt = kopf.startsWith("Bearer ") ? kopf.slice(7).trim() : "";
    if (!gleich(mitgeschickt, token)) {
      return c.json({ error: "Nicht angemeldet" }, 401);
    }
    await next();
  };
}
