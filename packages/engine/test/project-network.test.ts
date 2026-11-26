import { mkdirSync, mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ProjectTrustStore } from "@earendil-works/pi-coding-agent";
import { expect, test } from "vitest";
import { Projects } from "../src/projects.js";

// Which projects' commands get the filtered network (docs/spec/39): ones you open or clone, until you trust them.
test("a folder you open starts filtered unless it's trusted already; New project, trusting and the switch open it", () => {
	const base = realpathSync(mkdtempSync(join(tmpdir(), "piopio-net-")));
	const agentDir = join(base, "agent");
	mkdirSync(agentDir);
	const folder = (name: string) => (mkdirSync(join(base, name)), join(base, name));
	const projects = new Projects(join(base, "projects.json"), agentDir, join(base, "Piopio"));

	const cloned = projects.add(folder("cloned"));
	expect(cloned.network).toBe("filtered");
	expect(projects.networkFor(join(cloned.path, "src"))).toBe("filtered");

	const trustedAlready = folder("mine");
	new ProjectTrustStore(agentDir).set(trustedAlready, true);
	expect(projects.add(trustedAlready).network).toBe("open");

	expect(projects.create("Notes").network).toBe("open");

	expect(projects.configure(cloned.id, { trust: true }).network).toBe("open");
	expect(projects.networkFor(cloned.path)).toBe("open");
	expect(projects.configure(cloned.id, { network: "filtered" }).network).toBe("filtered");
	expect(projects.configure(cloned.id, { network: "open" }).network).toBe("open");

	// Projects from before this have no field: open.
	const again = new Projects(join(base, "projects.json"), agentDir, join(base, "Piopio"));
	expect(again.list().map((p) => p.network)).toEqual(["open", "open", "open"]);
	projects.addRule(cloned.path, { kind: "host", pattern: "api.example.com" });
	expect(projects.hostRules(cloned.path)).toEqual(["api.example.com"]);
});

test("Full access needs a trusted project: refused while filtered, allowed once trusted, undone by filtering", () => {
	const base = realpathSync(mkdtempSync(join(tmpdir(), "piopio-net-fa-")));
	const agentDir = join(base, "agent");
	mkdirSync(agentDir);
	mkdirSync(join(base, "cloned"));
	const projects = new Projects(join(base, "projects.json"), agentDir, join(base, "Piopio"));
	const p = projects.add(join(base, "cloned"));
	expect(() => projects.configure(p.id, { approvalMode: "full_auto" })).toThrow(/Full access needs a trusted project/);
	expect(projects.configure(p.id, { trust: true, approvalMode: "full_auto" }).approvalMode).toBe("full_auto");
	expect(projects.modeFor(p.path)).toBe("full_auto");
	expect(projects.configure(p.id, { network: "filtered" }).approvalMode).toBe("auto_edit");
	expect(projects.modeFor(p.path)).toBe("auto_edit");
});

// Off (docs/spec/39 §8): only this Mac, set by hand, and trusting the project doesn't turn it on.
test("a network turned off stays off through trust, keeps Full access away, and turns on only by hand", () => {
	const base = realpathSync(mkdtempSync(join(tmpdir(), "piopio-net-off-")));
	const agentDir = join(base, "agent");
	mkdirSync(agentDir);
	mkdirSync(join(base, "mine"));
	new ProjectTrustStore(agentDir).set(join(base, "mine"), true);
	const projects = new Projects(join(base, "projects.json"), agentDir, join(base, "Piopio"));
	const p = projects.add(join(base, "mine"));
	expect(projects.configure(p.id, { approvalMode: "full_auto" }).approvalMode).toBe("full_auto");

	// Turning it off moves Full access to Auto-edit, so commands are sandboxed.
	expect(projects.configure(p.id, { network: "off" })).toMatchObject({ network: "off", approvalMode: "auto_edit" });
	expect(projects.networkFor(join(p.path, "src"))).toBe("off");
	expect(() => projects.configure(p.id, { approvalMode: "full_auto" })).toThrow(/can't keep the network off/);
	expect(projects.configure(p.id, { trust: true }).network).toBe("off");
	expect(() => projects.configure(p.id, { trust: true, approvalMode: "full_auto" })).toThrow(/can't keep the network off/);

	// Kept across a restart; on again by hand, Full access is back.
	const again = new Projects(join(base, "projects.json"), agentDir, join(base, "Piopio"));
	expect(again.networkFor(p.path)).toBe("off");
	expect(again.configure(p.id, { network: "open", approvalMode: "full_auto" })).toMatchObject({ network: "open", approvalMode: "full_auto" });
});

