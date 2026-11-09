import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		globalSetup: ["test/global-setup.ts"],
		// Clears ambient PIOPIO_* variables a dev shell may export (see the file for why).
		setupFiles: ["../../vitest.setup.ts"],
		testTimeout: 30_000,
		hookTimeout: 60_000,
	},
});
