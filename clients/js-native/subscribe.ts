// Native-JS (non-browser) subscriber: run the published @moq/net + @moq/hang
// packages under a JS runtime that has no native WebTransport, using the
// @fails-components/webtransport polyfill (the same one @moq/clock uses). Runs
// under both bun and node (via tsx) -- see the smoke harness.
//
// Connect, read the .hang catalog to find the video track, subscribe it, and
// exit 0 as soon as any non-empty frame arrives (1 on timeout).
//
//   bun subscribe.ts subscribe --url http://127.0.0.1:4443 --broadcast b.hang --timeout 20
//
// Subscribe-only: publishing media needs a WebCodecs encoder, which a native JS
// runtime doesn't have. Reading raw container frames needs no codec.
import { quicheLoaded, WebTransport } from "@fails-components/webtransport";

// Polyfill WebTransport for bun/node, then import @moq/net (connect() picks up
// globalThis.WebTransport).
// @ts-ignore - assigning the polyfill onto globalThis
globalThis.WebTransport = WebTransport;

import { parseArgs } from "node:util";
import * as Catalog from "@moq/hang/catalog";
import * as Moq from "@moq/net";

const { positionals, values } = parseArgs({
	allowPositionals: true,
	options: {
		url: { type: "string" },
		broadcast: { type: "string" },
		timeout: { type: "string", default: "20" },
	},
});

const role = positionals[0];
const url = values.url;
const broadcast = values.broadcast;
const timeoutMs = Number.parseFloat(values.timeout ?? "20") * 1000;
if (role !== "subscribe" || !url || !broadcast) {
	console.error("usage: subscribe.ts subscribe --url U --broadcast B [--timeout S]");
	process.exit(2);
}

async function run(): Promise<void> {
	const connection = await Moq.Connection.connect(new URL(url as string));
	try {
		const bc = connection.consume(Moq.Path.from(broadcast as string));

		// The .hang catalog lives on the "catalog.json" track. A lazy publisher may
		// announce video in a later update, so keep reading frames until one has it.
		const catalog = bc.subscribe("catalog.json", Catalog.PRIORITY.catalog);
		let videoTrack: string | undefined;
		while (!videoTrack) {
			const root = await Catalog.fetch(catalog);
			if (!root) throw new Error("catalog ended without a video track");
			const renditions = root.video?.renditions;
			if (renditions) videoTrack = Object.keys(renditions)[0];
		}

		const video = bc.subscribe(videoTrack, 0);
		let total = 0;
		for (;;) {
			const group = await video.recvGroup();
			if (!group) break;
			for (;;) {
				const frame = await group.readFrame();
				if (!frame) break;
				total += frame.byteLength;
				if (total > 0) {
					console.error(`received ${total} bytes from ${broadcast}`);
					return;
				}
			}
		}
		throw new Error("no frame data received");
	} finally {
		connection.close(); // returns void, not a promise
	}
}

// Wait for the polyfill's quiche backend to load before connecting.
await quicheLoaded;

const timeout = new Promise<never>((_, reject) =>
	setTimeout(() => reject(new Error("timed out waiting for data")), timeoutMs),
);

try {
	await Promise.race([run(), timeout]);
	process.exit(0);
} catch (err) {
	console.error(`error: ${err instanceof Error ? err.message : String(err)}`);
	process.exit(1);
}
