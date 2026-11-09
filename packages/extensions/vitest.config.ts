import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		// Clears ambient PIOPIO_* variables a dev shell may export (see the file for why).
		setupFiles: ["../../vitest.setup.ts"],
	},
});
