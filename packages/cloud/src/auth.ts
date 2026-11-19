/**
 * The owner's token, checked at the Worker before anything reaches an agent's Durable Object. Without it, anyone who
 * knew the URL could open a socket, wake an object or create one per agent id they made up (each one stored and
 * billed). `engine.hello` still checks the same token inside the socket.
 */

/** Compares two secrets in constant time (both hashed first, so their lengths don't show). */
export async function sameSecret(a: string, b: string): Promise<boolean> {
	const enc = new TextEncoder();
	const [da, db] = await Promise.all([crypto.subtle.digest("SHA-256", enc.encode(a)), crypto.subtle.digest("SHA-256", enc.encode(b))]);
	const x = new Uint8Array(da);
	const y = new Uint8Array(db);
	let diff = 0;
	for (let i = 0; i < x.length; i++) diff |= x[i]! ^ y[i]!;
	return diff === 0;
}

/** The bearer token in `Authorization: Bearer <token>`, if any. */
export function bearer(request: Request): string | undefined {
	const m = /^Bearer\s+(\S+)\s*$/i.exec(request.headers.get("Authorization") ?? "");
	return m?.[1];
}

/**
 * Undefined when the request carries the owner's token; otherwise the response to send instead. A Worker deployed
 * without `OWNER_TOKEN` refuses everything rather than letting everyone in.
 */
export async function ownerOnly(request: Request, ownerToken: string | undefined): Promise<Response | undefined> {
	if (!ownerToken) return Response.json({ error: "This cloud engine has no owner token yet. Deploy it with OWNER_TOKEN set." }, { status: 503 });
	const token = bearer(request);
	if (token && (await sameSecret(token, ownerToken))) return undefined;
	return Response.json({ error: token ? "Bad owner token." : "Send the owner token as Authorization: Bearer <token>." }, { status: 401, headers: { "WWW-Authenticate": 'Bearer realm="piopio-cloud"' } });
}
