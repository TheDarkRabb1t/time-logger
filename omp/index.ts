// omp adapter: omp runs TS extensions, not Claude-style command hooks, so this
// feeds the same hook scripts the same JSON payload Claude Code and Codex send.
// All row, sidecar and summary logic stays in the scripts.

import { type ChildProcess, spawn } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

// session_shutdown handlers get 2 s in total. session-log.sh finishes in well
// under that; past the budget the child is left to finish on its own.
const END_BUDGET_MS = 1500;
const START_BUDGET_MS = 5000;

interface HookPayload {
	hook_event_name: "SessionStart" | "SessionEnd";
	session_id: string;
	cwd: string;
	transcript_path?: string;
}

// Runs a hook script detached, so it survives omp exiting mid-run, and resolves
// with its stdout once it exits or the budget runs out, whichever comes first.
function runHook(script: string, payload: HookPayload, budgetMs: number): Promise<string> {
	const { promise, resolve } = Promise.withResolvers<string>();
	let out = "";
	const settle = () => resolve(out);
	let child: ChildProcess;
	try {
		child = spawn("bash", [path.join(ROOT, script)], {
			cwd: payload.cwd,
			env: { ...process.env, WORKLOG_HARNESS: "omp" },
			stdio: ["pipe", "pipe", "ignore"],
			detached: true,
		});
	} catch {
		settle();
		return promise;
	}
	child.on("error", settle);
	child.on("close", settle);
	child.stdout?.on("data", chunk => {
		out += chunk;
	});
	child.stdin?.on("error", () => {});
	child.stdin?.end(JSON.stringify(payload));
	const timer = setTimeout(() => {
		try {
			child.unref();
		} catch {}
		settle();
	}, budgetMs);
	timer.unref?.();
	return promise;
}

async function sessionStart(ctx: ExtensionContext): Promise<void> {
	const payload: HookPayload = {
		hook_event_name: "SessionStart",
		session_id: ctx.sessionManager.getSessionId(),
		cwd: ctx.sessionManager.getCwd(),
	};
	const [out] = await Promise.all([
		runHook("hooks/session-start.sh", payload, START_BUDGET_MS),
		// Detaches itself after taking its lock; returns at once.
		runHook("hooks/worklog-reap.sh", payload, START_BUDGET_MS),
	]);
	// session-start.sh nudges through Claude's hookSpecificOutput when summaries
	// are left for /timelog. Shown to the user here, not put in the context.
	if (!out.trim() || !ctx.hasUI) return;
	try {
		const text = JSON.parse(out)?.hookSpecificOutput?.additionalContext;
		if (typeof text === "string" && text) ctx.ui.notify(text, "info");
	} catch {}
}

async function sessionEnd(ctx: ExtensionContext): Promise<void> {
	// No file until the first assistant reply, and none at all for --no-session.
	const transcript = ctx.sessionManager.getSessionFile();
	if (!transcript) return;
	await runHook(
		"hooks/session-log.sh",
		{
			hook_event_name: "SessionEnd",
			session_id: ctx.sessionManager.getSessionId(),
			cwd: ctx.sessionManager.getCwd(),
			transcript_path: transcript,
		},
		END_BUDGET_MS,
	);
}

export default function timeLogger(pi: ExtensionAPI): void {
	// The summary child runs `omp -p` with CLAUDE_WORKLOG_CHILD set and
	// extensions off; this is the backstop. Subagents are part of their parent's
	// session, not sessions of their own.
	if (process.env.CLAUDE_WORKLOG_CHILD) return;
	pi.setLabel("Time Logger");
	pi.on("session_start", async (_event, ctx) => {
		if (ctx.agent?.kind !== "sub") await sessionStart(ctx);
	});
	pi.on("session_shutdown", async (_event, ctx) => {
		if (ctx.agent?.kind !== "sub") await sessionEnd(ctx);
	});
	// /new, /resume and /fork leave one session for another without exiting:
	// close the old one before the switch, open the new one after it.
	pi.on("session_before_switch", async (_event, ctx) => {
		if (ctx.agent?.kind !== "sub") await sessionEnd(ctx);
	});
	pi.on("session_switch", async (_event, ctx) => {
		if (ctx.agent?.kind !== "sub") await sessionStart(ctx);
	});
}
