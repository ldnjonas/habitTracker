/// Sicherung ausgeben und einspielen.

import type { Hono } from "hono";
import type { Db } from "../db.ts";
import { exportBackup, importBackup } from "../backup.ts";
import type { BackupFile, ImportMode } from "../domain/backup.ts";
import { encodeBackup, normalizeBackup } from "../domain/backup.ts";
import { Fehler } from "../store.ts";
import { rumpf } from "./helfer.ts";

export function backupRouten(app: Hono, db: Db): void {

  // Bewusst als vorformatierter Text und nicht über die Serialisierung des
  // Rahmenwerks: eine Sicherung hat eine kanonische Form — sortierte Schlüssel,
  // keine leeren Felder —, damit dieselbe Datei nach einem Export aus dem
  // Browser nicht anders aussieht als nach einem vom Mac.
  app.get("/backup", async (c) => {
    const roh = c.req.query("habitIds");
    const ids = roh ? roh.split(",").map((s) => s.trim()).filter(Boolean) : undefined;
    const datei = await exportBackup(db, ids);
    return c.body(encodeBackup(datei), 200, {
      "content-type": "application/json; charset=utf-8",
      "content-disposition":
        `attachment; filename="habits-${datei.exportedAt.slice(0, 10)}.json"`,
    });
  });

  app.post("/backup/import", async (c) => {
    const wunsch = await rumpf<{ mode?: ImportMode; file?: BackupFile }>(c);
    if (wunsch.mode !== "merge" && wunsch.mode !== "replace") {
      throw new Fehler(400, "mode muss merge oder replace sein");
    }
    if (!wunsch.file) throw new Fehler(400, "file fehlt");
    // Durch dieselbe nachsichtige Lesung wie eine Datei: fehlende Listen sind
    // kein Fehler, sonst wäre jede Erweiterung des Formats ein Bruch.
    return c.json(await importBackup(db, normalizeBackup(wunsch.file), wunsch.mode));
  });
}
