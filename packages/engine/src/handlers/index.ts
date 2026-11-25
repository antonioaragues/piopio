/**
 * Every method of the protocol, and the function that answers it: `handlers/<prefix>.ts` holds the `<prefix>.*` methods
 * (a method's first word says where its code is). The map is typed against packages/protocol, so a method with no
 * handler doesn't compile, and each handler gets its method's params and must return its result.
 * A method with a new first word: a new file, added here.
 */
import type { Engine } from "../server.js";
import type { AllHandlers } from "./types.js";
import { engineHandlers } from "./engine.js";
import { sessionsHandlers } from "./sessions.js";
import { learnHandlers } from "./learn.js";
import { projectsHandlers } from "./projects.js";
import { browserHandlers } from "./browser.js";
import { mcpHandlers } from "./mcp.js";
import { packagesHandlers } from "./packages.js";
import { hooksHandlers } from "./hooks.js";
import { skillsHandlers } from "./skills.js";
import { settingsHandlers } from "./settings.js";
import { aboutMeHandlers } from "./aboutMe.js";
import { agentsHandlers } from "./agents.js";
import { homeHandlers } from "./home.js";
import { githubHandlers } from "./github.js";
import { workHandlers } from "./work.js";
import { automationsHandlers } from "./automations.js";
import { appsHandlers } from "./apps.js";
import { libraryHandlers } from "./library.js";
import { usageHandlers } from "./usage.js";
import { statsHandlers } from "./stats.js";
import { inboxHandlers } from "./inbox.js";
import { watchdogHandlers } from "./watchdog.js";
import { cloudHandlers } from "./cloud.js";
import { memoryHandlers } from "./memory.js";
import { gitHandlers } from "./git.js";
import { catalogHandlers } from "./catalog.js";
import { modelsHandlers } from "./models.js";
import { secretsHandlers } from "./secrets.js";
import { providersHandlers } from "./providers.js";
import { connectorsHandlers } from "./connectors.js";
import { endpointsHandlers } from "./endpoints.js";

export function handlersFor(engine: Engine): AllHandlers {
	return {
		...engineHandlers(engine),
		...sessionsHandlers(engine),
		...learnHandlers(engine),
		...projectsHandlers(engine),
		...browserHandlers(engine),
		...mcpHandlers(engine),
		...packagesHandlers(engine),
		...hooksHandlers(engine),
		...skillsHandlers(engine),
		...settingsHandlers(engine),
		...aboutMeHandlers(engine),
		...agentsHandlers(engine),
		...homeHandlers(engine),
		...githubHandlers(engine),
		...workHandlers(engine),
		...automationsHandlers(engine),
		...appsHandlers(engine),
		...libraryHandlers(engine),
		...usageHandlers(engine),
		...statsHandlers(engine),
		...inboxHandlers(engine),
		...watchdogHandlers(engine),
		...cloudHandlers(engine),
		...memoryHandlers(engine),
		...gitHandlers(engine),
		...catalogHandlers(engine),
		...modelsHandlers(engine),
		...secretsHandlers(engine),
		...providersHandlers(engine),
		...connectorsHandlers(engine),
		...endpointsHandlers(engine),
	};
}
