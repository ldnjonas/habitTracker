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

const hier = dirname(fileURLToPath(import.meta.url));

export type Zeile = Record<string, unknown>;

export class Db {
  private readonly db: DatabaseSync;

  constructor(pfad = ":memory:") {
    this.db = new DatabaseSync(pfad);
    // Fremdschlüssel sind in SQLite standardmäßig aus.
    this.db.exec("PRAGMA foreign_keys = ON");
    // WAL: Lesen blockiert Schreiben nicht. Bei einer Datei sinnvoll, im
    // Arbeitsspeicher wirkungslos.
    if (pfad !== ":memory:") this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec(readFileSync(join(hier, "schema.sql"), "utf8"));
  }

  alle(sql: string, ...werte: unknown[]): Zeile[] {
    return this.db.prepare(sql).all(...(werte as never[])) as Zeile[];
  }

  eine(sql: string, ...werte: unknown[]): Zeile | undefined {
    return this.db.prepare(sql).get(...(werte as never[])) as Zeile | undefined;
  }

  schreibe(sql: string, ...werte: unknown[]): void {
    this.db.prepare(sql).run(...(werte as never[]));
  }

  /// Alles oder nichts. Ein halb angewandtes Delta wäre schlimmer als ein
  /// abgelehntes: der Client hielte seinen Cursor für weiter, als er ist.
  inTransaktion<T>(arbeit: () => T): T {
    this.db.exec("BEGIN");
    try {
      const ergebnis = arbeit();
      this.db.exec("COMMIT");
      return ergebnis;
    } catch (fehler) {
      this.db.exec("ROLLBACK");
      throw fehler;
    }
  }

  /// Die nächste Nummer der Folge. Innerhalb einer Transaktion aufzurufen.
  naechsteSequenz(): number {
    this.db.exec("UPDATE sync_sequence SET value = value + 1 WHERE id = 1");
    const zeile = this.eine("SELECT value FROM sync_sequence WHERE id = 1");
    return Number(zeile!.value);
  }

  aktuelleSequenz(): number {
    return Number(this.eine("SELECT value FROM sync_sequence WHERE id = 1")!.value);
  }

  schliesse(): void {
    this.db.close();
  }
}
