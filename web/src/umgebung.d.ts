/// Was Vite zur Bauzeit einsetzt.
///
/// Bewusst von Hand statt über `"types": ["vite/client"]`: gebraucht wird
/// genau eine Variable, und `types: []` in `tsconfig.json` ist eine
/// Entscheidung — hier steht, was wirklich benutzt wird, und nicht alles, was
/// ein Werkzeug mitbringt.
interface ImportMetaEnv {
  readonly VITE_API_BASE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
