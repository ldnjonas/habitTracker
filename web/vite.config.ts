import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/// Gebaut wird nach `dist/`, und genau das liefert der Fastify-Server aus:
/// ein Ursprung, eine Adresse, kein CORS, eine Sache zum Starten.
///
/// Im Entwicklungsbetrieb läuft Vite dagegen auf einem eigenen Port und leitet
/// die API weiter — sonst müsste man für jede Änderung neu bauen.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: Object.fromEntries(
      ["/habits", "/tags", "/entries", "/days", "/exceptions", "/trash",
       "/focus", "/freezes", "/stats", "/insights", "/backup", "/sync", "/health"]
        .map((pfad) => [pfad, { target: "http://localhost:8080", changeOrigin: true }])),
  },
  build: { outDir: "dist", emptyOutDir: true },
});
