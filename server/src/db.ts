import postgres from "postgres";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/// Alles, was eine bestimmte Datenbank kennt, liegt in dieser Datei.
///
/// **Postgres, in zwei Ausprägungen.** Im Betrieb spricht `postgres.js` mit
/// Supabase; in den Tests läuft PGlite — dasselbe Postgres, nur nach WebAssembly
/// übersetzt und im selben Prozess. Damit bleibt `npm test` hermetisch und
/// schnell, statt einen Docker-Container vorauszusetzen, und trotzdem prüft es
/// echtes Postgres statt einer Nachbildung.
///
/// Die Ausprägung wird **spät** geladen: PGlite bringt mehrere Megabyte
/// WebAssembly mit und hat im Bündel einer Edge Function nichts verloren.

const hier = dirname(fileURLToPath(import.meta.url));

export type Zeile = Record<string, unknown>;

/// Was eine Datenbank können muss, damit `Db` mit ihr arbeitet.
///
/// Drei Methoden. Wäre sie größer, stünde hier die Hälfte des Servers noch
/// einmal — und jeder Wechsel wäre wieder ein Umbau statt eines Tauschs.
export interface Treiber {
  abfrage(sql: string, werte: unknown[]): Promise<Zeile[]>;
  /// Mehrere Anweisungen am Stück — für das Schema, sonst nichts.
  ausfuehren(sql: string): Promise<void>;
  schliesse(): Promise<void>;
}

/// `?` → `$1, $2, …`
///
/// Damit bleibt jede Abfrage in `store.ts`, `sync.ts` und `backup.ts` genau so
/// stehen, wie sie war. Die Umschreibung ist hier billig und an einer Stelle;
/// verteilt über 74 Abfragen wäre sie 74 Gelegenheiten, sich zu verzählen.
///
/// Zulässig, weil in keiner dieser Abfragen ein Fragezeichen in einer
/// Zeichenkette steht — die Werte kommen ausnahmslos als Platzhalter.
export function nummeriere(sql: string): string {
  let n = 0;
  return sql.replace(/\?/g, () => `$${++n}`);
}

export class Db {
  private readonly treiber: Treiber;

  private constructor(treiber: Treiber) {
    this.treiber = treiber;
  }

  /// Öffnet eine Datenbank.
  ///
  /// Beginnt `ziel` mit `postgres`, ist es eine Verbindungszeichenfolge und der
  /// Bestand liegt anderswo; sonst ist es ein Ordner (oder leer für „nur im
  /// Arbeitsspeicher") und PGlite legt ihn hier an. Nur im zweiten Fall wird
  /// das Schema angelegt — bei Supabase führen die Migrationen Regie.
  static async oeffne(ziel = ""): Promise<Db> {
    if (ziel.startsWith("postgres")) {
      // `prepare: false` ist für Supavisor im Transaktionsmodus nötig:
      // vorbereitete Anweisungen überleben dort den Verbindungswechsel nicht.
      // `max: 1` gibt jeder `Db` genau eine Verbindung — die Voraussetzung
      // dafür, dass `BEGIN` und `COMMIT` dieselbe Sitzung meinen.
      const sql = postgres(ziel, { max: 1, prepare: false });
      return new Db({
        abfrage: async (text, werte) =>
          await sql.unsafe(text, werte as never[]) as unknown as Zeile[],
        ausfuehren: async (text) => { await sql.unsafe(text).simple(); },
        schliesse: async () => { await sql.end(); },
      });
    }

    const { eingebettet } = await import("./pglite.ts");
    const db = new Db(await eingebettet(ziel));
    await db.legeSchemaAn();
    return db;
  }

  /// Für Tests und Werkzeuge, die ihren Treiber selbst mitbringen.
  static mitTreiber(treiber: Treiber): Db {
    return new Db(treiber);
  }

  async legeSchemaAn(): Promise<void> {
    await this.treiber.ausfuehren(readFileSync(join(hier, "schema.sql"), "utf8"));
    // Beim ersten Anlegen gewürfelt, danach unveränderlich.
    await this.schreibe(
      `INSERT INTO server_info (id, instance) VALUES (1, ?) ON CONFLICT (id) DO NOTHING`,
      crypto.randomUUID());
  }

  /// Wer dieser Server ist — siehe `server_info` in `schema.sql`.
  async instanz(): Promise<string> {
    const zeile = await this.eine("SELECT instance FROM server_info WHERE id = 1");
    return String(zeile!.instance);
  }

  async alle(sql: string, ...werte: unknown[]): Promise<Zeile[]> {
    return this.treiber.abfrage(nummeriere(sql), werte);
  }

  async eine(sql: string, ...werte: unknown[]): Promise<Zeile | undefined> {
    const zeilen = await this.alle(sql, ...werte);
    return zeilen[0];
  }

  async schreibe(sql: string, ...werte: unknown[]): Promise<void> {
    await this.alle(sql, ...werte);
  }

  /// Alles oder nichts. Ein halb angewandtes Delta wäre schlimmer als ein
  /// abgelehntes: der Client hielte seinen Cursor für weiter, als er ist.
  ///
  /// Innerhalb des Blocks wird weiter dasselbe `db` benutzt. Das trägt, weil
  /// eine `Db` genau eine Verbindung hat — ein Pool, aus dem sich jede Abfrage
  /// eine beliebige nähme, würde die Klammer sprengen, ohne dass der Typprüfer
  /// es merkt.
  async inTransaktion<T>(arbeit: () => Promise<T>): Promise<T> {
    await this.treiber.abfrage("BEGIN", []);
    try {
      const ergebnis = await arbeit();
      await this.treiber.abfrage("COMMIT", []);
      return ergebnis;
    } catch (fehler) {
      await this.treiber.abfrage("ROLLBACK", []);
      throw fehler;
    }
  }

  /// Die nächste Nummer der Folge. Innerhalb einer Transaktion aufzurufen.
  ///
  /// Ein `RETURNING` statt zweier Anweisungen: in Postgres ist das dieselbe
  /// Zeile und derselbe Sperrmoment, und es kann nichts dazwischenkommen.
  async naechsteSequenz(): Promise<number> {
    const zeile = await this.eine(
      "UPDATE sync_sequence SET value = value + 1 WHERE id = 1 RETURNING value");
    return Number(zeile!.value);
  }

  async aktuelleSequenz(): Promise<number> {
    const zeile = await this.eine("SELECT value FROM sync_sequence WHERE id = 1");
    return Number(zeile!.value);
  }

  async schliesse(): Promise<void> {
    await this.treiber.schliesse();
  }
}
