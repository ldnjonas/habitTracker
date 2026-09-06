/// Das Gerüst: Inhalt oben, Registerleiste unten.
///
/// Unten, weil die App auf dem Telefon einhändig bedient wird — oben kommt der
/// Daumen nicht hin. Jedes Register ist 58 px hoch und damit ein sicheres
/// Fingerziel.

export type Register = "heute" | "uebersicht" | "fokus" | "mehr";

const REGISTER: { schluessel: Register; zeichen: string; titel: string }[] = [
  { schluessel: "heute", zeichen: "✓", titel: "Heute" },
  { schluessel: "uebersicht", zeichen: "▦", titel: "Übersicht" },
  { schluessel: "fokus", zeichen: "◎", titel: "Fokus" },
  { schluessel: "mehr", zeichen: "⋯", titel: "Mehr" },
];

export function Schale({
  aktiv, waehle, children,
}: {
  aktiv: Register;
  waehle: (r: Register) => void;
  children: React.ReactNode;
}) {
  return (
    <div className="schale">
      <main className="inhalt">{children}</main>
      <nav className="registerleiste" aria-label="Bereiche">
        {REGISTER.map((r) => (
          <button
            key={r.schluessel}
            onClick={() => waehle(r.schluessel)}
            aria-current={aktiv === r.schluessel ? "page" : undefined}
          >
            <span className="zeichen" aria-hidden="true">{r.zeichen}</span>
            {r.titel}
          </button>
        ))}
      </nav>
    </div>
  );
}
