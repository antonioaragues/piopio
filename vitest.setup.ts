/**
 * Test isolation for the scripted suites.
 *
 * A dev shell that builds or runs the app exports `PIOPIO_*` variables (Xcode's scheme, the
 * engine launcher, `scripts/app-smoke.sh`). Several of those have ambient defaults in `src/` —
 * `OnDeviceModel` falls back to `PIOPIO_FM`, `enginePaths()` to `PIOPIO_HOME`, the approvals
 * extension to `PIOPIO_APPROVAL_MODE` — so a leaked variable silently changes what a test sees.
 * That is how `utility.test.ts` and `engine.test.ts` started failing on a machine with a built
 * `Piopio.app` while passing in CI.
 *
 * Clear the ambient ones here. Opt-in switches are deliberately kept: they only do something
 * when a test asks for it, and removing them would turn live tests into silent skips.
 */
const ambient = [
	// Point at the built app's helper.
	"PIOPIO_FM",
	// Engine configuration (`packages/engine/src/main.ts`, `paths.ts`, `agent-files.ts`).
	"PIOPIO_FAUX",
	"PIOPIO_HOME",
	"PIOPIO_PROJECTS_DIR",
	"PIOPIO_AGENTS_DIR",
	"PIOPIO_PI_SESSION_DIR",
	"PIOPIO_PI_AGENT_DIR",
	"PIOPIO_CONNECTOR_ENDPOINTS",
	"PIOPIO_HOOKS_PORT",
	// Shared resources and extensions.
	"PIOPIO_SEARCH_MODEL",
	"PIOPIO_APPROVAL_MODE",
	"PIOPIO_PLAN",
	// Set by the engine when a session gets its own pi agent dir.
	"PI_CODING_AGENT_DIR",
];

for (const name of ambient) delete process.env[name];

/** Kept on purpose: opt-in live tests read these; absent means "skip", never "different answer". */
export const optIn = ["OPENROUTER_API_KEY", "RECORD_FIXTURES", "PIOPIO_RECORD_DIR", "PIOPIO_DEFAULT_MODEL"] as const;
