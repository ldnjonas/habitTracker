/// Habit anlegen und ändern.
///
/// **Zeitplan und Ziel gehen einen eigenen Weg.** Sie sind versioniert: eine
/// Regel gilt ab einem Datum, und vergangene Tage werden mit der damals
/// gültigen bewertet. Deshalb fragt die Ansicht beim Ändern, ob die neue Regel
/// *ab heute* gelten oder die bestehende *rückwirkend korrigieren* soll — ohne
/// diese Unterscheidung legte jeder Tippfehler eine Version an, und der Verlauf
/// würde zum Flickenteppich.

import { useState } from "react";
import { api } from "../api/client.ts";
import type { CalendarDate, Habit, HabitKind, Schedule, Tag, Weekday } from "../api/types.ts";
import { Blatt, Feld, Karte } from "../ui/Blatt.tsx";
import { schreibe } from "../ui/laden.ts";
import { langesDatum, planText } from "../ui/text.ts";
import { zeichenFuer } from "../ui/symbole.ts";
import { gueltigeRegel } from "./HabitDetail.tsx";

const ARTEN: { wert: HabitKind; titel: string; erklaerung: string }[] = [
  { wert: "binary", titel: "Erledigt", erklaerung: "Abhaken oder nicht." },
  { wert: "quantity", titel: "Menge", erklaerung: "Gegen ein Ziel, etwa 2 L oder 30 min." },
  { wert: "avoid", titel: "Vermeiden",
    erklaerung: "Erfolg ist der Normalzustand; gemeldet wird nur der Verstoß." },
];

const FARBEN = ["#4F8DF7", "#FF9500", "#34C759", "#FF375F", "#5E5CE6",
                "#00C7BE", "#AF52DE", "#FFD60A"];

const SYMBOLE = [
  "checkmark.circle", "figure.run", "book.fill", "drop.fill", "leaf.fill",
  "bed.double.fill", "fork.knife", "dumbbell.fill", "brain.head.profile",
  "pencil", "guitars.fill", "cup.and.saucer.fill", "sunrise.fill",
  "moon.stars.fill", "heart.fill", "pills.fill", "bicycle", "figure.walk",
  "sparkles", "iphone", "wineglass.fill", "cube.fill",
];

const TAGESZEITEN: { wert: string | null; titel: string }[] = [
  { wert: null, titel: "Ohne" },
  { wert: "morning", titel: "Morgens" },
  { wert: "afternoon", titel: "Mittags" },
  { wert: "evening", titel: "Abends" },
  { wert: "night", titel: "Nachts" },
];

const WOCHENTAGE: { wert: Weekday; titel: string }[] = [
  { wert: 1, titel: "Mo" }, { wert: 2, titel: "Di" }, { wert: 3, titel: "Mi" },
  { wert: 4, titel: "Do" }, { wert: 5, titel: "Fr" }, { wert: 6, titel: "Sa" },
  { wert: 7, titel: "So" },
];

export function HabitEditor({
  habit, tags, heute, schliessen, fertig, abgemeldet,
}: {
  /// `null` heißt: neu anlegen.
  habit: Habit | null;
  tags: Tag[];
  heute: CalendarDate;
  schliessen: () => void;
  fertig: () => Promise<void>;
  abgemeldet: () => void;
}) {
  const bestehend = habit != null;
  const regel = habit ? gueltigeRegel(habit, heute) : null;

  const [name, setzeName] = useState(habit?.name ?? "");
  const [notizen, setzeNotizen] = useState(habit?.notes ?? "");
  const [art, setzeArt] = useState<HabitKind>(habit?.kind ?? "binary");
  const [farbe, setzeFarbe] = useState(habit?.colorHex ?? FARBEN[0]!);
  const [symbol, setzeSymbol] = useState(habit?.symbol ?? SYMBOLE[0]!);
  const [tageszeit, setzeTageszeit] = useState<string | null>(habit?.timeOfDay ?? null);
  const [zeiterfassung, setzeZeiterfassung] = useState(habit?.tracksTime ?? false);
  const [gewaehlteTags, setzeGewaehlteTags] = useState<Set<string>>(
    new Set(habit?.tagIds ?? []));

  const [plan, setzePlan] = useState<Schedule>(regel?.schedule ?? { kind: "daily" });
  const [zielwert, setzeZielwert] = useState(
    regel?.target ? String(regel.target.value) : "");
  const [einheit, setzeEinheit] = useState(regel?.target?.unit ?? "");
  const [vergleich, setzeVergleich] = useState(regel?.target?.comparison ?? "atLeast");
  /// Nur beim Ändern: ab wann die neue Regel gilt.
  const [abHeute, setzeAbHeute] = useState(true);

  const [meldung, setzeMeldung] = useState<string | null>(null);
  const [laeuft, setzeLaeuft] = useState(false);
  /// Löschen fragt einmal nach — zweimal denselben Knopf zu drücken ist eine
  /// bewusstere Geste als ein Dialog, den man wegklickt.
  const [loeschFrage, setzeLoeschFrage] = useState(false);

  async function archivieren() {
    if (!habit) return;
    setzeLaeuft(true);
    const gut = await schreibe(() => api.aendere(`/habits/${habit.id}`, {
      archivedOn: habit.archivedOn ? null : heute,
    }), fertig, setzeMeldung, abgemeldet);
    setzeLaeuft(false);
    if (gut) schliessen();
  }

  async function loeschen() {
    if (!habit) return;
    if (!loeschFrage) { setzeLoeschFrage(true); return; }
    setzeLaeuft(true);
    const gut = await schreibe(() => api.loesche(`/habits/${habit.id}`),
                               fertig, setzeMeldung, abgemeldet);
    setzeLaeuft(false);
    if (gut) schliessen();
  }

  const ziel = art === "quantity" && zielwert.trim() !== ""
    ? {
        value: Number(zielwert.replace(",", ".")),
        unit: einheit.trim() || "Stück",
        comparison: vergleich,
      }
    : null;

  async function speichern() {
    if (!name.trim()) { setzeMeldung("Ein Habit braucht einen Namen."); return; }
    setzeLaeuft(true);

    const gut = await schreibe(async () => {
      if (!bestehend) {
        const angelegt = await api.sende<Habit>("/habits", {
          name, notes: notizen.trim() || null, kind: art, colorHex: farbe, symbol,
          timeOfDay: tageszeit, tracksTime: zeiterfassung,
          rules: [{ effectiveFrom: heute, schedule: plan, target: ziel }],
          tagIds: [...gewaehlteTags],
        });
        return angelegt;
      }

      await api.aendere(`/habits/${habit.id}`, {
        name, notes: notizen.trim() || null, kind: art, colorHex: farbe, symbol,
        timeOfDay: tageszeit, tracksTime: zeiterfassung,
      });
      // Die Regel getrennt, über ihren eigenen Weg: „ab heute" legt eine neue
      // Version an, „rückwirkend" überschreibt die geltende.
      const ab = abHeute ? heute : regel?.effectiveFrom ?? heute;
      await api.setze(`/habits/${habit.id}/rules/${ab}`, { schedule: plan, target: ziel });
      await api.setze(`/habits/${habit.id}/tags`, [...gewaehlteTags]);
      return null;
    }, fertig, setzeMeldung, abgemeldet);

    setzeLaeuft(false);
    if (gut) schliessen();
  }

  return (
    <Blatt titel={bestehend ? "Habit ändern" : "Neuer Habit"} schliessen={schliessen}
           aktion={<button onClick={speichern} disabled={laeuft}>Sichern</button>}>
      {meldung && <div className="fehler">{meldung}</div>}

      <Karte>
        <Feld titel="Name">
          <input value={name} onChange={(e) => setzeName(e.target.value)}
                 placeholder="Sport" autoFocus={!bestehend} />
        </Feld>

        <Feld titel="Notiz">
          <textarea rows={2} value={notizen} onChange={(e) => setzeNotizen(e.target.value)} />
        </Feld>

        <Feld titel="Farbe">
          <div className="farbwahl">
            {FARBEN.map((f) => (
              <button key={f} aria-pressed={farbe === f} style={{ background: f }}
                      aria-label={f} onClick={() => setzeFarbe(f)} />
            ))}
          </div>
        </Feld>

        <Feld titel="Symbol">
          <div className="symbolwahl">
            {SYMBOLE.map((s) => (
              <button key={s} aria-pressed={symbol === s} onClick={() => setzeSymbol(s)}>
                {zeichenFuer(s, "?")}
              </button>
            ))}
          </div>
        </Feld>
      </Karte>

      <Karte titel="Art">
        <div className="segmente">
          {ARTEN.map((a) => (
            <button key={a.wert} role="tab" aria-selected={art === a.wert}
                    onClick={() => setzeArt(a.wert)}>{a.titel}</button>
          ))}
        </div>
        <p className="hinweis klein">{ARTEN.find((a) => a.wert === art)!.erklaerung}</p>

        {art === "quantity" && (
          <>
            <div className="nebeneinander">
              <Feld titel="Ziel">
                <input inputMode="decimal" value={zielwert}
                       onChange={(e) => setzeZielwert(e.target.value)} placeholder="2" />
              </Feld>
              <Feld titel="Einheit">
                <input value={einheit} onChange={(e) => setzeEinheit(e.target.value)}
                       placeholder="L" />
              </Feld>
            </div>
            <div className="segmente klein">
              <button role="tab" aria-selected={vergleich === "atLeast"}
                      onClick={() => setzeVergleich("atLeast")}>mindestens</button>
              <button role="tab" aria-selected={vergleich === "atMost"}
                      onClick={() => setzeVergleich("atMost")}>höchstens</button>
            </div>
          </>
        )}
      </Karte>

      <Karte titel="Zeitplan">
        <PlanWahl plan={plan} setze={setzePlan} heute={heute} />
        <p className="hinweis klein">Gilt als: {planText(plan)}</p>

        {bestehend && regel && (
          <>
            <div className="segmente klein">
              <button role="tab" aria-selected={abHeute} onClick={() => setzeAbHeute(true)}>
                Ab heute
              </button>
              <button role="tab" aria-selected={!abHeute} onClick={() => setzeAbHeute(false)}>
                Rückwirkend
              </button>
            </div>
            <p className="hinweis klein">
              {abHeute
                ? `Legt eine neue Version ab dem ${langesDatum(heute)} an. Vergangene Tage bleiben nach der alten Regel bewertet.`
                : `Überschreibt die Regel vom ${langesDatum(regel.effectiveFrom)} — für Tippfehler, nicht für echte Änderungen.`}
            </p>
          </>
        )}
      </Karte>

      {bestehend && (
        <Karte titel="Aus dem Weg räumen">
          <button className="breit" disabled={laeuft}
                  onClick={() => void archivieren()}>
            {habit.archivedOn ? "Aus dem Archiv holen" : "Archivieren"}
          </button>
          <p className="hinweis klein">
            Archiviert ist nicht gelöscht: der Habit verschwindet aus „Heute", bleibt aber in
            Verlauf und Statistik.
          </p>
          <button className="breit gefahr" disabled={laeuft}
                  onClick={() => void loeschen()}>
            {loeschFrage ? "Wirklich löschen?" : "Löschen"}
          </button>
          <p className="hinweis klein">
            Löschen nimmt Einträge, Sitzungen und Ausnahmen mit. Dreißig Tage lang steht alles
            im Papierkorb und kommt zusammen zurück.
          </p>
        </Karte>
      )}

      <Karte titel="Sonstiges">
        <Feld titel="Tageszeit" hinweis="Ordnet die Heute-Ansicht.">
          <div className="segmente klein">
            {TAGESZEITEN.map((t) => (
              <button key={t.titel} role="tab" aria-selected={tageszeit === t.wert}
                      onClick={() => setzeTageszeit(t.wert)}>{t.titel}</button>
            ))}
          </div>
        </Feld>

        <label className="schalter">
          <input type="checkbox" checked={zeiterfassung}
                 onChange={(e) => setzeZeiterfassung(e.target.checked)} />
          <span>Sitzungen mit Start und Ende</span>
        </label>
        <p className="hinweis klein">
          Dann ist der Tageswert die Summe der Sitzungen und wird nicht von Hand gesetzt.
        </p>

        {tags.length > 0 && (
          <Feld titel="Tags">
            <div className="auswahl">
              {tags.map((t) => (
                <button key={t.id} aria-pressed={gewaehlteTags.has(t.id)}
                        onClick={() => setzeGewaehlteTags((alt) => {
                          const neu = new Set(alt);
                          if (neu.has(t.id)) neu.delete(t.id); else neu.add(t.id);
                          return neu;
                        })}>{t.name}</button>
              ))}
            </div>
          </Feld>
        )}
      </Karte>
    </Blatt>
  );
}

function PlanWahl({
  plan, setze, heute,
}: {
  plan: Schedule;
  setze: (p: Schedule) => void;
  heute: CalendarDate;
}) {
  return (
    <>
      <div className="segmente klein">
        <button role="tab" aria-selected={plan.kind === "daily"}
                onClick={() => setze({ kind: "daily" })}>Täglich</button>
        <button role="tab" aria-selected={plan.kind === "weekdays"}
                onClick={() => setze({ kind: "weekdays", days: [1, 3, 5] })}>Wochentage</button>
        <button role="tab" aria-selected={plan.kind === "timesPerWeek"}
                onClick={() => setze({ kind: "timesPerWeek", n: 3 })}>× pro Woche</button>
        <button role="tab" aria-selected={plan.kind === "everyNDays"}
                onClick={() => setze({ kind: "everyNDays", n: 3, anchor: heute })}>Alle n Tage</button>
      </div>

      {plan.kind === "weekdays" && (
        <div className="auswahl">
          {WOCHENTAGE.map((t) => (
            <button key={t.wert} aria-pressed={plan.days.includes(t.wert)}
                    onClick={() => {
                      const dabei = plan.days.includes(t.wert);
                      const neu = dabei
                        ? plan.days.filter((d) => d !== t.wert)
                        : [...plan.days, t.wert].sort((a, b) => a - b);
                      // Ohne einen einzigen Tag wäre der Habit nie fällig.
                      if (neu.length > 0) setze({ kind: "weekdays", days: neu });
                    }}>{t.titel}</button>
          ))}
        </div>
      )}

      {plan.kind === "timesPerWeek" && (
        <Feld titel="Wie oft je Woche"
              hinweis="Der Tag ist egal — bewertet wird die Woche, nicht der einzelne Tag.">
          <input inputMode="numeric" value={String(plan.n)}
                 onChange={(e) => setze({
                   kind: "timesPerWeek",
                   n: Math.max(1, Math.min(7, Number(e.target.value) || 1)),
                 })} />
        </Feld>
      )}

      {plan.kind === "everyNDays" && (
        <Feld titel="Alle wie viele Tage" hinweis={`Gerechnet ab dem ${langesDatum(plan.anchor)}.`}>
          <input inputMode="numeric" value={String(plan.n)}
                 onChange={(e) => setze({
                   kind: "everyNDays",
                   n: Math.max(1, Number(e.target.value) || 1),
                   anchor: plan.anchor,
                 })} />
        </Feld>
      )}
    </>
  );
}
