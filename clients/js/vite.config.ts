import { defineConfig } from "vite";

// The published @moq/publish already inlines its audio worklets at build time,
// so a consumer needs no special plugin. esnext keeps WebCodecs/WebTransport
// syntax intact.
export default defineConfig({
	build: { target: "esnext" },
});
