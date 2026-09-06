import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/// Alles, was auf `node:sqlite` zeigt, liegt in dieser Datei.
///
/// Das Modul ist in Node noch als erprobend gekennzeichnet. Die benutzte
/// Schnittstelle ist winzig — `exec`, `prepare`, `run`, `get`, `all` —, und
/// wenn sie sich ändert, ist der Austausch gegen `better-sqlite3` ein Eingriff
/// an einer Stelle statt im ganzen Server.
///
/// **Warum jede Methode ein Versprechen zurückgibt, obwohl SQLite synchron
/// ist.** Weil Postgres es nicht ist. Eine Datenbank am anderen Ende einer
/// Verbindung kann gar nicht synchron antworten, und diese Schnittstelle ist
/// die Stelle, an der später getauscht wird. Sie jetzt asynchron zu machen
/// kostet `await` an den Aufrufstellen — sie später asynchron zu machen würde
/// dasselbe kosten, nur mitten in einem Umzug, bei dem gleichzeitig der Dialekt
/// und der Wirt wechseln. Ein Schritt nach dem anderen.

const hier = dirname(fileURLToPath(import.meta.url));

export type Zeile = Record<string, unknown>;

export class Db {
  // Kein Parameter-Property: `erasableSyntaxOnly` verbietet es, weil Node die
  // Typen nur entfernt und nichts erzeugt.
  private readonly db: DatabaseSync;

  private constructor(db: DatabaseSync) {
    this.db = db;
  }

  /// Öffnet eine Datenbank und legt das Schema an, falls es fehlt.
  ///
  /// Kein `new Db(...)` mehr: gegen Postgres ist schon das Öffnen eine
  /// Netzsache, und ein Konstruktor kann nicht warten.
  static async oeffne(pfad = ":memory:"): Promise<Db> {
    const roh = new DatabaseSync(pfad);
    // Fremdschlüssel sind in SQLite standardmäßig aus.
    roh.exec("PRAGMA foreign_keys = ON");
    // WAL: Lesen blockiert Schreiben nicht. Bei einer Datei sinnvoll, im
    // Arbeitsspeicher wirkungslos.
    if (pfad !== ":memory:") roh.exec("PRAGMA journal_mode = WAL");
    roh.exec(readFileSync(join(hier, "schema.sql"), "utf8"));
    // Beim ersten Öffnen einer Datei gewürfelt, danach unveränderlich.
    roh.exec(
      `INSERT OR IGNORE INTO server_info (id, instance) VALUES (1, '${crypto.randomUUID()}')`);
    return new Db(roh);
  }

  /// Wer dieser Server ist — siehe `server_info` in `schema.sql`.
  async instanz(): Promise<string> {
    const zeile = await this.eine("SELECT instance FROM server_info WHERE id = 1");
    return String(zeile!.instance);
  }

  async alle(sql: string, ...werte: unknown[]): Promise<Zeile[]> {
    return this.db.prepare(sql).all(...(werte as never[])) as Zeile[];
  }

  async eine(sql: string, ...werte: unknown[]): Promise<Zeile | undefined> {
    return this.db.prepare(sql).get(...(werte as never[])) as Zeile | undefined;
  }

  async schreibe(sql: string, ...werte: unknown[]): Promise<void> {
    this.db.prepare(sql).run(...(werte as never[]));
  }

  /// Alles oder nichts. Ein halb angewandtes Delta wäre schlimmer als ein
  /// abgelehntes: der Client hielte seinen Cursor für weiter, als er ist.
  ///
  /// Innerhalb des Blocks wird weiter dasselbe `db` benutzt — das ist Absicht
  /// und bleibt auch gegen Postgres tragfähig, solange **eine Anfrage eine
  /// Verbindung** hat. Ein Pool, aus dem jede Abfrage sich eine beliebige
  /// Verbindung nimmt, würde die Klammer sprengen, ohne dass der Typprüfer es
  /// merkt.
  async inTransaktion<T>(arbeit: () => Promise<T>): Promise<T> {
    this.db.exec("BEGIN");
    try {
      const ergebnis = await arbeit();
      this.db.exec("COMMIT");
      return ergebnis;
    } catch (fehler) {
      this.db.exec("ROLLBACK");
      throw fehler;
    }
  }

  /// Die nächste Nummer der Folge. Innerhalb einer Transaktion aufzurufen.
  async naechsteSequenz(): Promise<number> {
    await this.schreibe("UPDATE sync_sequence SET value = value + 1 WHERE id = 1");
    return this.aktuelleSequenz();
  }

  async aktuelleSequenz(): Promise<number> {
    const zeile = await this.eine("SELECT value FROM sync_sequence WHERE id = 1");
    return Number(zeile!.value);
  }

  async schliesse(): Promise<void> {
    this.db.close();
  }
}
