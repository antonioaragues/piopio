#!/usr/bin/env node
/**
 * piopio-engine. Env:
 *   PIOPIO_HOME                 data folder (default ~/Library/Application Support/Piopio)
 *   PIOPIO_FAUX=1               use the scripted echo model instead of OpenRouter
 *   PIOPIO_ALLOW_ENV_SECRETS=1  let OPENROUTER_API_KEY from the environment answer secret requests
 *   PIOPIO_PI_SESSION_DIR / PIOPIO_PI_AGENT_DIR   override pi's folders (tests)
 */
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { acquireEngineLock } from "./lock.js";
import { logLine, rotateLog } from "./logs.js";
import { Engine, type ConnectorEndpoints } from "./server.js";
import { enginePaths } from "./paths.js";

const paths = enginePaths();
// Before anything opens a file in the folder: a second engine stops here, not after its migrations ran.
mkdirSync(paths.home, { recursive: true, mode: 0o700 });
const release = await acquireEngineLock(paths.lockFile, paths.socket).catch((error: unknown) => {
	process.stderr.write(logLine(`piopio-engine: ${error instanceof Error ? error.message : String(error)}`));
	process.exit(1);
});
process.on("exit", () => release());

// The log the app or the launcher opened for our stderr: rotated at start and once an hour, each line with its time.
const logFile = join(paths.logsDir, "engine.log");
rotateLog(logFile);
setInterval(() => rotateLog(logFile), 3600_000).unref();
const log = (line: string) => void process.stderr.write(logLine(line));

const engine = new Engine({
	onShutdown: () => void shutdown("backup or restore"),
	paths,
	log,
	faux: process.env.PIOPIO_FAUX === "1",
	...(process.env.PIOPIO_PI_SESSION_DIR ? { piSessionDir: process.env.PIOPIO_PI_SESSION_DIR } : {}),
	...(process.env.PIOPIO_PI_AGENT_DIR ? { piAgentDir: process.env.PIOPIO_PI_AGENT_DIR } : {}),
	// Dev and captures with the scripted model only: point connected apps at a fake server (JSON, see ConnectorEndpoints).
	...(process.env.PIOPIO_FAUX === "1" && process.env.PIOPIO_CONNECTOR_ENDPOINTS ? { connectorEndpoints: JSON.parse(process.env.PIOPIO_CONNECTOR_ENDPOINTS) as ConnectorEndpoints } : {}),
});

let stopping = false;
async function shutdown(signal: string) {
	if (stopping) return;
	stopping = true;
	process.stderr.write(logLine(`piopio-engine: ${signal}, shutting down`));
	await engine.stop().catch(() => undefined);
	process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));

await engine.listen().catch((error: unknown) => {
	process.stderr.write(logLine(`piopio-engine: ${error instanceof Error ? error.message : String(error)}`));
	process.exit(1);
});
