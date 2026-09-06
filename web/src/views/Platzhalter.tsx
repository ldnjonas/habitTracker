/// Was noch nicht gebaut ist, sagt es — statt eine leere Seite zu zeigen.
///
/// Übersicht und Detail kommen in W4, Fokus, Journal und der Rest in W5. Ein
/// Register, das ohne Erklärung nichts tut, ist schlimmer als eines, das nicht
/// da ist; eines, das sagt was fehlt, ist besser als beides.

export function Platzhalter({ titel, text }: { titel: string; text: string }) {
  return (
    <>
      <header className="kopf">
        <h1>{titel}</h1>
      </header>
      <p className="hinweis">{text}</p>
    </>
  );
}
