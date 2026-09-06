/// SF-Symbole gibt es im Browser nicht.
///
/// Die Mac-App speichert einen Symbolnamen wie `figure.run`. Damit dasselbe
/// Habit auf dem Telefon nicht anonym aussieht, steht hier für jede Wahl aus
/// dem Editor (`HabitEditor.swift`, `choices`) ein Emoji. Bewusst eine Tabelle
/// und keine Bibliothek: 23 Zeichen wiegen nichts, ein Icon-Paket schon.
///
/// Was nicht in der Liste steht, bekommt den ersten Buchstaben seines Namens —
/// besser als ein Fragezeichen.

const TABELLE: Record<string, string> = {
  "checkmark.circle": "✓",
  "figure.run": "🏃",
  "book.fill": "📖",
  "drop.fill": "💧",
  "leaf.fill": "🌿",
  "bed.double.fill": "🛏️",
  "fork.knife": "🍽️",
  "dumbbell.fill": "🏋️",
  "brain.head.profile": "🧠",
  "pencil": "✏️",
  "guitars.fill": "🎸",
  "cup.and.saucer.fill": "☕️",
  "sunrise.fill": "🌅",
  "moon.stars.fill": "🌙",
  "heart.fill": "❤️",
  "pills.fill": "💊",
  "bicycle": "🚲",
  "figure.walk": "🚶",
  "sparkles": "✨",
  "iphone": "📱",
  "wineglass.fill": "🍷",
  "cube.fill": "🧊",
};

export function zeichenFuer(symbol: string, name: string): string {
  const bekannt = TABELLE[symbol];
  if (bekannt) return bekannt;
  return name.trim().charAt(0).toUpperCase() || "•";
}
