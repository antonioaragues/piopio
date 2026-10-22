/** Turns provider error text (pi-ai puts the HTTP status first, e.g. `401 {...}`) into something a person can act on. */
import type { ErrorKind } from "@piopio/protocol";

/** How errors name a provider (docs/spec/10 FR4: the user should know which account to fix). */
const PROVIDER_NAMES: Record<string, string> = { openrouter: "OpenRouter", openai: "ChatGPT", "openai-api": "The OpenAI API", anthropic: "Anthropic", google: "Gemini", "github-copilot": "GitHub Copilot", xai: "xAI" };

export function describeModelError(raw: string | undefined, provider = "openrouter"): { kind: ErrorKind; message: string } {
	const name = PROVIDER_NAMES[provider] ?? provider.charAt(0).toUpperCase() + provider.slice(1);
	const text = raw ?? "";
	const status = Number(/^\s*(\d{3})\b/.exec(text)?.[1] ?? NaN);
	const lower = text.toLowerCase();
	if (status === 401 || status === 403 || /invalid api key|authentication|unauthori[sz]ed|user not found/.test(lower)) {
		return { kind: "auth", message: provider === "openrouter" ? "OpenRouter rejected the API key. Update it in Settings." : `${name} didn't accept the sign-in or key. Reconnect it in Settings › Models.` };
	}
	if (status === 402 || /insufficient credits|payment required|more credits/.test(lower)) {
		return { kind: "credits", message: provider === "openrouter" ? "Your OpenRouter account is out of credits." : `${name} says the account is out of credits.` };
	}
	if (/usage limit|quota|plan limit|limit reached|exceeded your current/.test(lower)) {
		return { kind: "credits", message: `${name} says you've reached your plan's limit. Try again later, or pick a model from another provider.` };
	}
	if (/context length|context window|maximum context|too many tokens|prompt is too long/.test(lower)) {
		return { kind: "context", message: "This conversation is too long for the model. Start a new thread or pick a model with a larger context." };
	}
	if (status === 404 || /no endpoints found|model not found|is not a valid model|no such model/.test(lower)) {
		return { kind: "model", message: "This model isn't available right now. Pick another one." };
	}
	if (status === 429 || /rate limit|too many requests/.test(lower)) {
		return { kind: "rate_limit", message: "The provider is rate limiting requests. Try again in a moment." };
	}
	if (status >= 500 || /overloaded|bad gateway|service unavailable|upstream/.test(lower)) {
		return { kind: "provider", message: `The model provider had a problem${Number.isFinite(status) ? ` (${status})` : ""}. Try again.` };
	}
	if (/fetch failed|econnrefused|enotfound|etimedout|network|socket hang up|getaddrinfo/.test(lower)) {
		return { kind: "network", message: `Can't reach ${provider === "openrouter" ? "OpenRouter" : name}. Check your internet connection.` };
	}
	const firstLine = text.split("\n")[0]?.trim() ?? "";
	return { kind: "other", message: firstLine.length > 0 ? firstLine.slice(0, 300) : "The model request failed." };
}
