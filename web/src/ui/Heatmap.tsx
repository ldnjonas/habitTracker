/// Die Heatmap als **inline SVG**, ohne Diagrammbibliothek.
///
/// 371 Rechtecke sind kein Grund für 200 kB. Und die Farbstufe rechnet nicht
/// diese Datei aus, sondern der Server (`intensityLevel`) — läge sie hier,
/// zeigten Mac und Browser für denselben Bestand verschiedene Bilder.

import type { CalendarDate, DaySummary } from "../api/types.ts";
import { langesDatum, wochentag } from "./text.ts";

/// Fünf Stufen, wortgleich mit `OverviewHeatmapView.opacity(for:)` auf dem Mac.
const DECKKRAFT = [0, 0.25, 0.45, 0.7, 1.0];

export type Ausschnitt = "week" | "month" | "year";

export type Tag = {
  date: CalendarDate;
  summary: DaySummary | null;
  /// 0…4, vom Server gerechnet.
  level: number;
  /// Ausnahme an diesem Tag, falls eine gilt.
  ausnahme?: string | null;
  /// Für einen einzelnen Habit: die Deckkraft unmittelbar statt über die fünf
  /// Stufen. „Wie viele von vielen" ist die Frage der Übersicht; bei einem
  /// einzelnen zählt der Status des Tages, und der ist feiner abgestuft.
  deckkraft?: number;
};

/// Kantenlänge und Abstand je Ausschnitt.
///
/// Im Jahr bleibt die Zelle bei 13 px, auch wenn 53 Wochen dann breiter sind
/// als ein Telefon — die Fläche scrollt lieber, als dass man auf Punkte tippen
/// muss, die man nicht trifft.
const MASSE: Record<Ausschnitt, { zelle: number; luecke: number }> = {
  week: { zelle: 40, luecke: 6 },
  month: { zelle: 38, luecke: 6 },
  year: { zelle: 13, luecke: 3 },
};

export function Heatmap({
  ausschnitt, tage, farbe = "#4f8df7", ausgewaehlt, waehle,
}: {
  ausschnitt: Ausschnitt;
  tage: Tag[];
  farbe?: string;
  ausgewaehlt?: CalendarDate | null;
  waehle?: (tag: Tag) => void;
}) {
  const { zelle, luecke } = MASSE[ausschnitt];
  const schritt = zelle + luecke;

  // Wochen als Spalten, Wochentage als Zeilen — das GitHub-Bild. Bei der
  // Wochenansicht ist das genau eine Spalte je Tag, also eine Zeile.
  const spalten = ausschnitt === "week" ? tage.map((t) => [t]) : inWochen(tage);
  const breite = spalten.length * schritt - luecke;
  const hoehe = (ausschnitt === "week" ? 1 : 7) * schritt - luecke;

  return (
    <div className={ausschnitt === "year" ? "heatmap scrollt" : "heatmap"}>
      <svg
        viewBox={`0 0 ${breite} ${hoehe}`}
        width={ausschnitt === "year" ? breite : undefined}
        style={ausschnitt === "year" ? undefined : { width: "100%", height: "auto" }}
        role="img"
        aria-label="Heatmap"
      >
        {spalten.map((spalte, x) =>
          spalte.map((tag) => {
            const y = ausschnitt === "week" ? 0 : wochentag(tag.date) - 1;
            const staerke = tag.deckkraft ?? DECKKRAFT[Math.min(4, tag.level)]!;
            const leer = staerke === 0;
            return (
              <rect
                key={tag.date}
                x={x * schritt}
                y={y * schritt}
                width={zelle}
                height={zelle}
                rx={Math.max(2, zelle * 0.22)}
                fill={leer ? "var(--rand)" : farbe}
                fillOpacity={leer ? 1 : staerke}
                stroke={ausgewaehlt === tag.date ? "var(--text)" : "none"}
                strokeWidth={1.5}
                onClick={waehle ? () => waehle(tag) : undefined}
                style={waehle ? { cursor: "pointer" } : undefined}
              >
                <title>{beschriftung(tag)}</title>
              </rect>
            );
          }))}
      </svg>
    </div>
  );
}

/// Gruppiert nach Kalenderwochen, angefangen beim Montag.
///
/// Die erste Spalte kann unvollständig sein, wenn der Zeitraum mitten in einer
/// Woche beginnt — dann bleiben die Zeilen darüber leer, statt die Tage nach
/// oben zu schieben und die Wochentagszeilen zu verschieben.
function inWochen(tage: Tag[]): Tag[][] {
  const spalten: Tag[][] = [];
  let aktuell: Tag[] = [];
  for (const tag of tage) {
    if (wochentag(tag.date) === 1 && aktuell.length > 0) {
      spalten.push(aktuell);
      aktuell = [];
    }
    aktuell.push(tag);
  }
  if (aktuell.length > 0) spalten.push(aktuell);
  return spalten;
}

export function beschriftung(tag: Tag): string {
  const datum = langesDatum(tag.date);
  if (tag.ausnahme) return `${datum} — ${AUSNAHME_TEXT[tag.ausnahme] ?? tag.ausnahme}`;
  if (!tag.summary || tag.summary.scheduled === 0) return `${datum} — nichts geplant`;
  return `${datum} — ${tag.summary.completed} von ${tag.summary.scheduled} erledigt`;
}

export const AUSNAHME_TEXT: Record<string, string> = {
  frozen: "Eingefroren",
  paused: "Urlaub",
  skipped: "Ruhetag",
};

/// Die Legende — ohne sie ist eine Farbskala eine Behauptung.
export function Legende({ farbe = "#4f8df7" }: { farbe?: string }) {
  return (
    <div className="legende">
      <span>weniger</span>
      {DECKKRAFT.map((deckkraft, i) => (
        <span
          key={i}
          className="stufe-punkt"
          style={{
            background: i === 0 ? "var(--rand)" : farbe,
            opacity: i === 0 ? 1 : deckkraft,
          }}
        />
      ))}
      <span>mehr</span>
    </div>
  );
}
