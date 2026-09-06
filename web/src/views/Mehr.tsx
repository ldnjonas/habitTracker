/// Alles, was nicht ins tägliche Abhaken gehört.
///
/// Eine Liste von Einstiegen statt vier weiterer Register: was man selten
/// braucht, soll auffindbar sein und nicht ständig im Weg stehen.

import { useRef, useState } from "react";
import { api, istAbgemeldet, vergissToken } from "../api/client.ts";
import type {
  BackupFile, CalendarDate, Habit, ImportReport, PapierkorbEintrag, Tag,
} from "../api/types.ts";
import { Blatt, Karte, Zeile } from "../ui/Blatt.tsx";
import { schreibe, useLaden } from "../ui/laden.ts";
import { langesDatum, planText } from "../ui/text.ts";
import { zeichenFuer } from "../ui/symbole.ts";
import { gueltigeRegel } from "./HabitDetail.tsx";

type Unterseite = "habits" | "tags" | "journal" | "papierkorb" | "sicherung" | null;

export function Mehr({
  heute, abgemeldet, oeffneHabit, oeffneJournal, neuerHabit, bearbeiteHabit,
}: {
  heute: CalendarDate;
  abgemeldet: () => void;
  oeffneHabit: (habit: Habit) => void;
  oeffneJournal: () => void;
  neuerHabit: () => void;
  bearbeiteHabit: (habit: Habit) => void;
}) {
  const [seite, setzeSeite] = useState<Unterseite>(null);

  return (
    <>
      <header className="kopf"><h1>Mehr</h1></header>

      <div className="liste">
        <Eintrag titel="Alle Habits" unter="Anlegen, ändern, sortieren, archivieren"
                 waehle={() => setzeSeite("habits")} />
        <Eintrag titel="Journal" unter="Stimmung, Energie, Schlaf — und Zusammenhänge"
                 waehle={oeffneJournal} />
        <Eintrag titel="Tags" unter="Gruppen für die Filter" waehle={() => setzeSeite("tags")} />
        <Eintrag titel="Papierkorb" unter="Gelöschtes der letzten 30 Tage"
                 waehle={() => setzeSeite("papierkorb")} />
        <Eintrag titel="Sicherung" unter="Als Datei sichern und einspielen"
                 waehle={() => setzeSeite("sicherung")} />
      </div>

      <Karte titel="Zugang">
        <p className="hinweis klein">
          Das Token liegt in diesem Browser. Wer ihn öffnen kann, kommt damit an die Daten —
          auf einem geteilten Gerät solltest du dich abmelden.
        </p>
        <button className="breit" onClick={() => { vergissToken(); abgemeldet(); }}>
          Abmelden
        </button>
      </Karte>

      {seite === "habits" && (
        <HabitListe heute={heute} schliessen={() => setzeSeite(null)}
                    oeffne={oeffneHabit} neu={neuerHabit} bearbeite={bearbeiteHabit}
                    abgemeldet={abgemeldet} />
      )}
      {seite === "tags" && (
        <TagListe schliessen={() => setzeSeite(null)} abgemeldet={abgemeldet} />
      )}
      {seite === "papierkorb" && (
        <Papierkorb schliessen={() => setzeSeite(null)} abgemeldet={abgemeldet} />
      )}
      {seite === "sicherung" && (
        <Sicherung schliessen={() => setzeSeite(null)} abgemeldet={abgemeldet} />
      )}
    </>
  );
}

function Eintrag({ titel, unter, waehle }: { titel: string; unter: string; waehle: () => void }) {
  return (
    <button className="zeile" onClick={waehle}>
      <span className="mitte">
        <span className="name">{titel}</span>
        <span className="unter">{unter}</span>
      </span>
      <span className="pfeil" aria-hidden="true">›</span>
    </button>
  );
}

// MARK: - Habits

function HabitListe({
  heute, schliessen, oeffne, neu, bearbeite, abgemeldet,
}: {
  heute: CalendarDate;
  schliessen: () => void;
  oeffne: (habit: Habit) => void;
  neu: () => void;
  bearbeite: (habit: Habit) => void;
  abgemeldet: () => void;
}) {
  const [mitArchiv, setzeMitArchiv] = useState(false);
  const [meldung, setzeMeldung] = useState<string | null>(null);

  const { daten, fehler, neuLaden } = useLaden(
    () => api.hole<Habit[]>(`/habits?includeArchived=${mitArchiv}`),
    [mitArchiv], abgemeldet);

  /// Verschieben über Knöpfe statt Ziehen: auf einem Telefon ist Ziehen in
  /// einer scrollenden Liste eine Wette, und `sortOrder` will ohnehin nur
  /// getauscht werden.
  async function verschiebe(index: number, richtung: -1 | 1) {
    if (!daten) return;
    const anderer = daten[index + richtung];
    const dieser = daten[index];
    if (!anderer || !dieser) return;
    await schreibe(async () => {
      await api.aendere(`/habits/${dieser.id}`, { sortOrder: anderer.sortOrder });
      await api.aendere(`/habits/${anderer.id}`, { sortOrder: dieser.sortOrder });
    }, neuLaden, setzeMeldung, abgemeldet);
  }

  return (
    <Blatt titel="Alle Habits" schliessen={schliessen}
           aktion={<button onClick={neu}>Neu</button>}>
      {fehler && <div className="fehler">{fehler}</div>}
      {meldung && <div className="fehler">{meldung}</div>}

      <label className="schalter">
        <input type="checkbox" checked={mitArchiv}
               onChange={(e) => setzeMitArchiv(e.target.checked)} />
        <span>Archivierte anzeigen</span>
      </label>

      {!daten ? <div className="laedt">Wird geladen …</div> : (
        <div className="liste">
          {daten.map((habit, index) => {
            const regel = gueltigeRegel(habit, heute);
            return (
              <div className="zeile" key={habit.id}>
                <span className="marke"
                      style={{ background: `${habit.colorHex}22`, color: habit.colorHex }}>
                  {zeichenFuer(habit.symbol, habit.name)}
                </span>
                <button className="mitte blank" onClick={() => oeffne(habit)}>
                  <span className="name">
                    {habit.name}
                    {habit.archivedOn && <span className="chip">archiviert</span>}
                  </span>
                  <span className="unter">{regel ? planText(regel.schedule) : "ohne Zeitplan"}</span>
                </button>
                <span className="sortier">
                  <button aria-label="nach oben" disabled={index === 0}
                          onClick={() => verschiebe(index, -1)}>↑</button>
                  <button aria-label="nach unten" disabled={index === daten.length - 1}
                          onClick={() => verschiebe(index, 1)}>↓</button>
                </span>
                <button className="leise" aria-label="Ändern"
                        onClick={() => bearbeite(habit)}>⋯</button>
              </div>
            );
          })}
        </div>
      )}

      <p className="hinweis klein">
        Umsortiert wird über die Pfeile. Archivieren und Löschen stehen im Habit selbst —
        archiviert verschwindet er aus „Heute", bleibt aber im Verlauf.
      </p>
    </Blatt>
  );
}

// MARK: - Tags

function TagListe({ schliessen, abgemeldet }: { schliessen: () => void; abgemeldet: () => void }) {
  const [neuerName, setzeNeuerName] = useState("");
  const [meldung, setzeMeldung] = useState<string | null>(null);
  const { daten, fehler, neuLaden } = useLaden(
    () => api.hole<Tag[]>("/tags"), [], abgemeldet);

  return (
    <Blatt titel="Tags" schliessen={schliessen}>
      {fehler && <div className="fehler">{fehler}</div>}
      {meldung && <div className="fehler">{meldung}</div>}

      <Karte>
        <div className="nebeneinander">
          <input value={neuerName} onChange={(e) => setzeNeuerName(e.target.value)}
                 placeholder="Neuer Tag" />
          <button disabled={!neuerName.trim()}
                  onClick={() => void schreibe(
                    async () => {
                      await api.sende("/tags", { name: neuerName.trim() });
                      setzeNeuerName("");
                    }, neuLaden, setzeMeldung, abgemeldet)}>Anlegen</button>
        </div>
      </Karte>

      {!daten ? <div className="laedt">Wird geladen …</div> : daten.length === 0 ? (
        <p className="hinweis">Noch keine Tags.</p>
      ) : (
        <div className="liste">
          {daten.map((tag) => (
            <div className="zeile" key={tag.id}>
              <span className="mitte"><span className="name">{tag.name}</span></span>
              <button className="leise" aria-label="Löschen"
                      onClick={() => void schreibe(
                        () => api.loesche(`/tags/${tag.id}`),
                        neuLaden, setzeMeldung, abgemeldet)}>×</button>
            </div>
          ))}
        </div>
      )}
    </Blatt>
  );
}

// MARK: - Papierkorb

function Papierkorb({ schliessen, abgemeldet }: { schliessen: () => void; abgemeldet: () => void }) {
  const [meldung, setzeMeldung] = useState<string | null>(null);
  const { daten, fehler, neuLaden } = useLaden(
    () => api.hole<PapierkorbEintrag[]>("/trash"), [], abgemeldet);

  const TABELLE_TEXT: Record<string, string> = {
    habit: "Habit", tag: "Tag", entry: "Eintrag",
  };

  return (
    <Blatt titel="Papierkorb" schliessen={schliessen}>
      {fehler && <div className="fehler">{fehler}</div>}
      {meldung && <div className="fehler">{meldung}</div>}

      {!daten ? <div className="laedt">Wird geladen …</div> : daten.length === 0 ? (
        <p className="hinweis">Nichts gelöscht — jedenfalls nicht in den letzten 30 Tagen.</p>
      ) : (
        <div className="liste">
          {daten.map((eintrag) => (
            <div className="zeile" key={`${eintrag.table}-${eintrag.rowId}`}>
              <span className="mitte">
                <span className="name">{eintrag.label}</span>
                <span className="unter">
                  {TABELLE_TEXT[eintrag.table] ?? eintrag.table} · gelöscht am{" "}
                  {langesDatum(eintrag.deletedAt.slice(0, 10) as CalendarDate)}
                </span>
              </span>
              <button onClick={() => void schreibe(
                () => api.sende("/trash/restore", {
                  table: eintrag.table, rowId: eintrag.rowId,
                }), neuLaden, setzeMeldung, abgemeldet)}>Zurück</button>
            </div>
          ))}
        </div>
      )}

      <p className="hinweis klein">
        Ein wiederhergestellter Habit bringt mit, was mit ihm gefallen ist — nicht aber, was
        vorher einzeln gelöscht wurde. Nach 30 Tagen ist Schluss: ein späteres
        Zurückholen brächte etwas wieder, das andere Geräte längst verarbeitet haben.
      </p>
    </Blatt>
  );
}

// MARK: - Sicherung

function Sicherung({ schliessen, abgemeldet }: { schliessen: () => void; abgemeldet: () => void }) {
  const [meldung, setzeMeldung] = useState<string | null>(null);
  const [bericht, setzeBericht] = useState<ImportReport | null>(null);
  const [modus, setzeModus] = useState<"merge" | "replace">("merge");
  const dateiFeld = useRef<HTMLInputElement>(null);

  async function sichern() {
    try {
      const datei = await api.hole<BackupFile>("/backup");
      const text = JSON.stringify(datei, null, 2);
      const url = URL.createObjectURL(new Blob([text], { type: "application/json" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = `habits-${datei.exportedAt.slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
      setzeMeldung(null);
    } catch (f) {
      if (istAbgemeldet(f)) return abgemeldet();
      setzeMeldung(f instanceof Error ? f.message : "Sichern fehlgeschlagen");
    }
  }

  async function einspielen(datei: File) {
    try {
      const inhalt = JSON.parse(await datei.text());
      const antwort = await api.sende<ImportReport>("/backup/import", { mode: modus, file: inhalt });
      setzeBericht(antwort);
      setzeMeldung(null);
    } catch (f) {
      if (istAbgemeldet(f)) return abgemeldet();
      setzeBericht(null);
      setzeMeldung(f instanceof Error ? f.message : "Einspielen fehlgeschlagen");
    }
  }

  return (
    <Blatt titel="Sicherung" schliessen={schliessen}>
      {meldung && <div className="fehler">{meldung}</div>}

      <Karte titel="Sichern">
        <p className="hinweis klein">
          Dieselbe Datei, die die Mac-App schreibt — lesbar, vergleichbar und in beide
          Richtungen verwendbar. Enthalten sind nur lebende Zeilen.
        </p>
        <button className="breit haupt" onClick={sichern}>Datei herunterladen</button>
      </Karte>

      <Karte titel="Einspielen">
        <div className="segmente klein">
          <button role="tab" aria-selected={modus === "merge"}
                  onClick={() => setzeModus("merge")}>Zusammenführen</button>
          <button role="tab" aria-selected={modus === "replace"}
                  onClick={() => setzeModus("replace")}>Ersetzen</button>
        </div>
        <p className="hinweis klein">
          {modus === "merge"
            ? "Vorhandenes wird nur überschrieben, wenn die Datei neuer ist. Nichts geht verloren."
            : "Der bisherige Bestand wird als gelöscht markiert und durch die Datei ersetzt. Andere Geräte erfahren davon beim nächsten Abgleich."}
        </p>
        <input ref={dateiFeld} type="file" accept="application/json,.json"
               onChange={(e) => {
                 const datei = e.target.files?.[0];
                 if (datei) void einspielen(datei);
                 e.target.value = "";
               }} hidden />
        <button className="breit" onClick={() => dateiFeld.current?.click()}>
          Datei wählen …
        </button>
      </Karte>

      {bericht && (
        <Karte titel="Eingespielt">
          {Object.entries(bericht.counts).map(([tabelle, zahlen]) => (
            zahlen.inserted + zahlen.updated + zahlen.skipped === 0 ? null : (
              <Zeile key={tabelle} label={tabelle}
                     wert={`${zahlen.inserted} neu · ${zahlen.updated} aktualisiert · ${zahlen.skipped} unverändert`} />
            )
          ))}
          {bericht.problems.length > 0 && (
            <p className="hinweis klein">
              {bericht.problems.length} Auffälligkeit(en) — siehe Serverantwort.
            </p>
          )}
        </Karte>
      )}

      <p className="hinweis klein">
        Der Mac sichert zusätzlich täglich von selbst. Diese Seite ist für den Fall, dass eine
        Sicherung woandershin soll — oder von woanders kommt.
      </p>
    </Blatt>
  );
}
