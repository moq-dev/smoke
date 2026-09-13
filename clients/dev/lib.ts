// Shared helpers for the from-dev API contract cases.
import * as Moq from "@moq/net";

export const REPLAY_MS = 30_000;

export function parseUrl(): { url: URL; timeoutMs: number } {
	const args = process.argv.slice(2);
	let url: string | undefined;
	let timeout = "30";
	for (let i = 0; i < args.length; i++) {
		if (args[i] === "--url") url = args[++i];
		else if (args[i] === "--timeout") timeout = args[++i] ?? timeout;
	}
	if (!url) {
		console.error("usage: run.ts --url URL [--timeout S]");
		process.exit(2);
	}
	return { url: new URL(url), timeoutMs: Number.parseFloat(timeout) * 1000 };
}

export async function waitUntil(pred: () => boolean, label: string, ms = 10_000): Promise<void> {
	const deadline = Date.now() + ms;
	for (;;) {
		if (pred()) return;
		if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`);
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
}

export async function connected(conn: Moq.Connection, ms = 10_000): Promise<Moq.Origin.Producer> {
	await waitUntil(
		() => conn.status.peek() === "connected" && conn.origin.peek() !== undefined,
		"connection established",
		ms,
	);
	const origin = conn.origin.peek();
	if (!origin) throw new Error("connected without an origin");
	return origin;
}

export function announcedPath(entry: Moq.Announce.Event): string | undefined {
	return entry.pattern.isLiteral ? entry.pattern.text : entry.pattern.asPrefix();
}

export async function waitAnnounce(
	announced: Moq.Announce.Consumer,
	path: string,
	active: boolean,
): Promise<void> {
	for (;;) {
		const entry = await announced.next();
		if (!entry) throw new Error(`announce stream ended before ${path} ${active ? "appeared" : "retracted"}`);
		if (announcedPath(entry) === path && entry.active === active) return;
	}
}

export async function waitActive(
	request: Moq.Origin.Request,
	label: string,
	ms = 10_000,
): Promise<Moq.Broadcast.Consumer> {
	await waitUntil(() => request.active.peek() !== undefined, label, ms);
	const broadcast = request.active.peek();
	if (!broadcast) throw new Error(`${label}: request resolved then vanished`);
	return broadcast;
}

export function equal(a: unknown, b: unknown): boolean {
	return JSON.stringify(a) === JSON.stringify(b);
}

export function handle(url: URL): Moq.Connection {
	// Private loops so a publisher and a subscriber do not share an origin and skip the relay.
	return new Moq.Connection({ url, share: false, linger: 0 });
}
