/**
 * Worker `piopio-cloud` (spike S4 subset): routes `GET /v1/ws?agent=<id>` to that agent's AgentDO.
 * Auth happens inside the socket (`engine.hello` with the owner token).
 */
import { CLOUD_VERSION } from "./agent-do.js";
import type { Env } from "./env.js";

export { AgentDO } from "./agent-do.js";

const AGENT_ID = /^[A-Za-z0-9_-]{1,64}$/;

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/v1/health") return Response.json({ ok: true, version: CLOUD_VERSION });

		const agent = url.searchParams.get("agent") ?? "default";
		if (!AGENT_ID.test(agent)) return new Response("Bad agent id", { status: 400 });

		if (url.pathname === "/v1/ws") {
			if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket upgrade", { status: 426 });
			return env.AGENT.getByName(agent).fetch(request);
		}
		if (env.PIOPIO_TEST_HOOKS && url.pathname.startsWith("/__test/")) return env.AGENT.getByName(agent).fetch(request);
		return new Response("Not found", { status: 404 });
	},
} satisfies ExportedHandler<Env>;
