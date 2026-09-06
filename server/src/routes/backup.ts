/// Sicherung ausgeben und einspielen.

import type { FastifyInstance } from "fastify";
import type { Db } from "../db.ts";
import { exportBackup, importBackup } from "../backup.ts";
import type { BackupFile, ImportMode } from "../domain/backup.ts";
import { encodeBackup, normalizeBackup } from "../domain/backup.ts";
import { Fehler } from "../store.ts";
import { rumpf } from "./helfer.ts";

export function backupRouten(app: FastifyInstance, db: Db): void {

  // Bewusst als vorformatierter Text und nicht über Fastifys Serialisierung:
  // eine Sicherung hat eine kanonische Form — sortierte Schlüssel, keine
  // leeren Felder —, damit dieselbe Datei nach einem Export aus dem Browser
  // nicht anders aussieht als nach einem vom Mac.
  app.get("/backup", async (anfrage, antwort) => {
    const abfrage = anfrage.query as { habitIds?: string };
    const ids = abfrage.habitIds
      ? abfrage.habitIds.split(",").map((s) => s.trim()).filter(Boolean)
      : undefined;
    const datei = await exportBackup(db, ids);
    return antwort
      .type("application/json; charset=utf-8")
      .header("content-disposition",
              `attachment; filename="habits-${datei.exportedAt.slice(0, 10)}.json"`)
      .send(encodeBackup(datei));
  });

  app.post("/backup/import", async (anfrage) => {
    const wunsch = rumpf<{ mode?: ImportMode; file?: BackupFile }>(anfrage);
    if (wunsch.mode !== "merge" && wunsch.mode !== "replace") {
      throw new Fehler(400, "mode muss merge oder replace sein");
    }
    if (!wunsch.file) throw new Fehler(400, "file fehlt");
    // Durch dieselbe nachsichtige Lesung wie eine Datei: fehlende Listen sind
    // kein Fehler, sonst wäre jede Erweiterung des Formats ein Bruch.
    return await importBackup(db, normalizeBackup(wunsch.file), wunsch.mode);
  });
}
