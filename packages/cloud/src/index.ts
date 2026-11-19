/**
 * Worker `piopio-cloud`: routes `GET /v1/ws?agent=<id>` to that agent's AgentDO.
 * Everything but `/v1/health` needs the owner's token (`Authorization: Bearer …`) before it reaches an object;
 * `engine.hello` checks it again inside the socket.
 */
import { CLOUD_VERSION } from "./agent-do.js";
import { ownerOnly } from "./auth.js";
import { SECRET_HEADER } from "./telegram.js";
import type { Env } from "./env.js";

export { AgentDO } from "./agent-do.js";

const AGENT_ID = /^[A-Za-z0-9_-]{1,64}$/;

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/v1/health") return Response.json({ ok: true, version: CLOUD_VERSION });

		// Telegram's webhook: no owner token (Telegram can't send one); the agent checks Telegram's secret header.
		const telegram = /^\/v1\/channels\/telegram\/([A-Za-z0-9_-]{1,64})$/.exec(url.pathname);
		if (telegram) {
			if (request.method !== "POST" || !request.headers.get(SECRET_HEADER)) return new Response("Unauthorized", { status: 401 });
			return env.AGENT.getByName(telegram[1]!).fetch(request);
		}

		const ws = url.pathname === "/v1/ws";
		// Test routes exist only where PIOPIO_TEST_HOOKS is set (tests; the deploy script never sends it), and even
		// there they need the owner's token.
		const test = Boolean(env.PIOPIO_TEST_HOOKS) && url.pathname.startsWith("/__test/");
		if (!ws && !test) return new Response("Not found", { status: 404 });

		const refused = await ownerOnly(request, env.OWNER_TOKEN);
		if (refused) return refused;

		const agent = url.searchParams.get("agent") ?? "default";
		if (!AGENT_ID.test(agent)) return new Response("Bad agent id", { status: 400 });
		if (ws && request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket upgrade", { status: 426 });
		return env.AGENT.getByName(agent).fetch(request);
	},
} satisfies ExportedHandler<Env>;
