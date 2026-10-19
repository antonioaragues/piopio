export interface Env {
	AGENT: DurableObjectNamespace<import("./agent-do.js").AgentDO>;
	/** Owner bearer token, checked by `engine.hello`. */
	OWNER_TOKEN: string;
	OPENROUTER_API_KEY?: string;
	/** `provider/model-id` for new sessions. Default: DEFAULT_MODEL in models.ts. */
	PIOPIO_DEFAULT_MODEL?: string;
	/** Any value: use pi-ai's faux echo model instead of OpenRouter (dev, tests). */
	PIOPIO_FAUX_MODEL?: string;
	/** Faux model speed in tokens per second (4 characters each). */
	PIOPIO_FAUX_TPS?: string;
	/** Any value: enable test-only routes (`/__test/status`). Never set in production. */
	PIOPIO_TEST_HOOKS?: string;
}
