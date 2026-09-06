/// Eine Ansicht über der Ansicht.
///
/// Auf dem Telefon ist ein Detail kein Fenster daneben, sondern eines darüber,
/// und der Weg zurück muss ohne Nachdenken erreichbar sein: links oben, groß
/// genug für den Daumen, immer an derselben Stelle. Zusätzlich schließt die
/// Escape-Taste — auf dem Mac im Browser ist das die erwartete Geste.

import { useEffect } from "react";

export function Blatt({
  titel, schliessen, aktion, children,
}: {
  titel: string;
  schliessen: () => void;
  /// Optional rechts oben — was hier steht, ist die eine Sache, die diese
  /// Ansicht tun kann.
  aktion?: React.ReactNode;
  children: React.ReactNode;
}) {
  useEffect(() => {
    const taste = (e: KeyboardEvent) => { if (e.key === "Escape") schliessen(); };
    window.addEventListener("keydown", taste);
    return () => window.removeEventListener("keydown", taste);
  }, [schliessen]);

  return (
    <div className="blatt" role="dialog" aria-label={titel}>
      <header className="blatt-kopf">
        <button className="zurueck" onClick={schliessen} aria-label="Zurück">‹</button>
        <span className="blatt-titel">{titel}</span>
        <span className="blatt-aktion">{aktion}</span>
      </header>
      <div className="blatt-inhalt">{children}</div>
    </div>
  );
}

/// Ein Feld mit Beschriftung — die Grundform aller Formulare hier.
export function Feld({
  titel, hinweis, children,
}: {
  titel: string;
  hinweis?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="feld">
      <span className="feld-titel">{titel}</span>
      {children}
      {hinweis && <span className="feld-hinweis">{hinweis}</span>}
    </label>
  );
}

export function Karte({ titel, children }: { titel?: string; children: React.ReactNode }) {
  return (
    <section className="karte">
      {titel && <h2>{titel}</h2>}
      {children}
    </section>
  );
}

export function Zeile({ label, wert }: { label: string; wert: React.ReactNode }) {
  return (
    <div className="wertzeile">
      <span>{label}</span>
      <strong>{wert}</strong>
    </div>
  );
}
