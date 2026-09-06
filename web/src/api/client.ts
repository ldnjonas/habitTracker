/// Der Zugang zum Server: Token, Aufrufe, Fehler.
///
/// **Das Token liegt im `localStorage`.** Wer den Browser hat, hat den Zugang —
/// auf einem privaten Telefon vertretbar, aber es ist eine Entscheidung und
/// keine Selbstverständlichkeit. Über Tailscale liegt zusätzlich
/// Verschlüsselung darunter.

const SCHLUESSEL = "habit-token";

/// Wo die API liegt.
///
/// Leer, solange derselbe Server die WebApp ausliefert — dann sind die Aufrufe
/// relativ, es gibt einen Ursprung und kein CORS. Liegt die App woanders
/// (Cloudflare Pages) als die API (Supabase), steht hier zur Bauzeit die
/// vollständige Adresse.
const BASIS = (import.meta.env.VITE_API_BASE ?? "").replace(/\/$/, "");

function adresse(pfad: string): string {
  return BASIS + pfad;
}

export function token(): string | null {
  try {
    return localStorage.getItem(SCHLUESSEL);
  } catch {
    // Privater Modus oder gesperrte Website-Daten: dann eben kein Token.
    return null;
  }
}

export function setzeToken(wert: string): void {
  try {
    localStorage.setItem(SCHLUESSEL, wert.trim());
  } catch {
    // Nichts zu retten — der Aufrufer sieht es daran, dass `token()` leer bleibt.
  }
}

export function vergissToken(): void {
  try {
    localStorage.removeItem(SCHLUESSEL);
  } catch { /* siehe oben */ }
}

export class ApiFehler extends Error {
  readonly status: number;

  constructor(status: number, nachricht: string) {
    super(nachricht);
    this.name = "ApiFehler";
    this.status = status;
  }
}

/// Ob dieser Fehler heißt „das Token stimmt nicht".
export function istAbgemeldet(fehler: unknown): boolean {
  return fehler instanceof ApiFehler && fehler.status === 401;
}

async function ruf<T>(methode: string, pfad: string, rumpf?: unknown): Promise<T> {
  const kopf: Record<string, string> = {};
  const t = token();
  if (t) kopf.authorization = `Bearer ${t}`;
  if (rumpf !== undefined) kopf["content-type"] = "application/json";

  let antwort: Response;
  try {
    antwort = await fetch(adresse(pfad), {
      method: methode,
      headers: kopf,
      body: rumpf === undefined ? undefined : JSON.stringify(rumpf),
    });
  } catch {
    // Kein Netz ist kein Serverfehler. Der Unterschied gehört in die Meldung,
    // sonst sucht man den Fehler an der falschen Stelle.
    throw new ApiFehler(0, "Der Server ist nicht erreichbar");
  }

  if (antwort.status === 204) return undefined as T;

  const text = await antwort.text();
  const inhalt = text ? sicherGelesen(text) : null;

  if (!antwort.ok) {
    const meldung = (inhalt as { error?: string } | null)?.error
      ?? `${antwort.status} ${antwort.statusText}`;
    throw new ApiFehler(antwort.status, meldung);
  }
  return inhalt as T;
}

function sicherGelesen(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export const api = {
  hole: <T>(pfad: string) => ruf<T>("GET", pfad),
  setze: <T>(pfad: string, rumpf: unknown) => ruf<T>("PUT", pfad, rumpf),
  sende: <T>(pfad: string, rumpf: unknown) => ruf<T>("POST", pfad, rumpf),
  aendere: <T>(pfad: string, rumpf: unknown) => ruf<T>("PATCH", pfad, rumpf),
  loesche: (pfad: string) => ruf<void>("DELETE", pfad),
};

/// Prüft ein Token, ohne es zu speichern.
export async function tokenPasst(kandidat: string): Promise<boolean> {
  const antwort = await fetch(adresse("/habits"), {
    headers: { authorization: `Bearer ${kandidat.trim()}` },
  });
  return antwort.ok;
}
