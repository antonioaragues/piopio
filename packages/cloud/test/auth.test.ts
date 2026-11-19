/** The owner check at the Worker (src/auth.ts), outside workerd. */
import { expect, test } from "vitest";
import { bearer, ownerOnly, sameSecret } from "../src/auth.ts";

const req = (authorization?: string) => new Request("https://x.workers.dev/v1/ws", authorization ? { headers: { Authorization: authorization } } : {});

test("only the owner's bearer token passes; a Worker without one refuses everyone", async () => {
	expect(await ownerOnly(req("Bearer s3cret"), "s3cret")).toBeUndefined();
	expect(await ownerOnly(req("bearer   s3cret  "), "s3cret")).toBeUndefined();
	expect((await ownerOnly(req(), "s3cret"))?.status).toBe(401);
	expect((await ownerOnly(req("Bearer nope"), "s3cret"))?.status).toBe(401);
	expect((await ownerOnly(req("Basic s3cret"), "s3cret"))?.status).toBe(401);
	expect((await ownerOnly(req("Bearer s3cret"), undefined))?.status).toBe(503);
	expect((await ownerOnly(req("Bearer "), ""))?.status).toBe(503);
	expect(bearer(req("Bearer a b"))).toBeUndefined();
	expect(await sameSecret("a", "a")).toBe(true);
	expect(await sameSecret("a", "ab")).toBe(false);
});
