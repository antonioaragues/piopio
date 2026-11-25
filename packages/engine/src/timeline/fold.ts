/** How a turn's tool calls fold into steps lines for clients that ask for it (`fold` in sessions.open and sessions.subscribe). */
import type { TimelineItem, ToolItem } from "@piopio/protocol";
import { groupSteps } from "./steps.js";
import { replacedVisuals } from "../tools/visuals.js";

/** Subagents keep their own card (it opens their session). */
/** Tools that stay their own item when steps fold: subagent tasks, questions you answered, plans, files handed over, visuals and apps made (they read as part of the conversation). */
const keepAlone = (tool: ToolItem) => tool.tool === "make_app" || tool.tool === "task" || tool.tool === "ask_user" || tool.tool === "ask_owner" || tool.tool === "ask_agent" || tool.tool === "offer_parallel" || tool.tool === "side_offer" || tool.tool === "propose_learnings" || tool.tool === "side_start" || tool.tool === "side_propose" || tool.tool === "automate" || tool.tool === "change_automation" || tool.tool === "propose_plan" || tool.tool === "present_files" || tool.tool === "show_visual";
/** Folds a turn's tool calls into steps lines; a visual that a later one replaced (docs/spec/25 §3.4) folds in too. */
export const fold = (items: readonly TimelineItem[]): TimelineItem[] => {
	const replaced = replacedVisuals(items);
	return groupSteps(items, (tool) => keepAlone(tool) && !replaced.has(tool.id));
};
