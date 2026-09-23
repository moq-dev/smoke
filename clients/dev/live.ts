// Connection, announcements, credential refresh, and publication replacement.
// Models the moq.pro live session (reconnecting handle, URL swap, announce cursor)
// without copying that app.
import * as Moq from "@moq/net";
import { connected, handle, REPLAY_MS, waitActive, waitAnnounce, waitUntil } from "./lib.ts";

const PATH = "dev.live";

export async function live(url: URL): Promise<void> {
	await refresh(url);
	await announceAndReplace(url);
	console.log("  live: ok");
}

async function refresh(url: URL): Promise<void> {
	const first = new URL(url.href);
	first.searchParams.set("jwt", "first");
	const second = new URL(url.href);
	second.searchParams.set("jwt", "second");

	const conn = handle(first);
	try {
		await connected(conn);
		if (conn.closed.peek() !== undefined) {
			throw new Error("closed settled before the handle was released");
		}

		conn.url.set(second);
		await waitUntil(
			() => conn.url.peek()?.href === second.href && conn.status.peek() === "connected",
			"connected at the refreshed URL",
		);
		if (conn.closed.peek() !== undefined) {
			throw new Error("closed settled on a URL swap; it is handle disposal, not session end");
		}
		if (conn.error.peek() !== undefined) {
			throw new Error(`error after a recoverable URL swap: ${conn.error.peek()}`);
		}
	} finally {
		conn.close();
	}

	const closed = await conn.closed;
	if (closed !== null) throw new Error(`close() settled with ${closed}`);
}

async function announceAndReplace(url: URL): Promise<void> {
	const pub = handle(url);
	const sub = handle(url);
	try {
		const pubOrigin = await connected(pub);
		const subOrigin = await connected(sub);
		const announced = sub.announced();

		const first = publish(pubOrigin, PATH, "v1");
		await waitAnnounce(announced, PATH, true);

		const request = subOrigin.request(Moq.Path.from(PATH));
		const consumer = await waitActive(request, "first publication");
		await expectFrame(consumer, "v1");

		first.broadcast.close();
		await waitAnnounce(announced, PATH, false);

		const second = publish(pubOrigin, PATH, "v2");
		await waitAnnounce(announced, PATH, true);
		const replaced = await waitActive(request, "replaced publication");
		await expectFrame(replaced, "v2");

		second.broadcast.close();
	} finally {
		pub.close();
		sub.close();
	}
}

function publish(origin: Moq.Origin.Table, path: string, payload: string) {
	const broadcast = origin.createBroadcast(Moq.Path.from(path));
	const track = broadcast.createTrack("messages");
	const group = track.appendGroup();
	group.writeString(payload);
	group.close();
	broadcast.announce();
	return { broadcast, track };
}

async function expectFrame(broadcast: Moq.Broadcast.Consumer, payload: string): Promise<void> {
	const track = broadcast.track("messages").subscribe({ priority: 0, maxAge: REPLAY_MS });
	try {
		const group = await track.recvGroup();
		if (!group) throw new Error("track ended before a group arrived");
		const frame = await group.readString();
		if (frame !== payload) throw new Error(`expected ${payload}, got ${frame}`);
	} finally {
		track.close();
	}
}
