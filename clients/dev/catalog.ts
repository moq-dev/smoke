// Catalog-only reading: Json.Snapshot.Consumer plus the hang catalog schema.
// A full snapshot is followed by a merge-patch delta. Parsing every frame as a
// catalog is the old consumer path and must fail on the delta frame.
import * as Catalog from "@moq/hang/catalog";
import * as Json from "@moq/json";
import * as Moq from "@moq/net";
import { connected, equal, handle, REPLAY_MS, waitActive, waitAnnounce } from "./lib.ts";

const PATH = "dev.catalog";

const SNAPSHOT: Catalog.Root = {
	json: {
		tracks: {
			status: { mode: "snapshot" },
		},
	},
};

const UPDATED: Catalog.Root = {
	json: {
		tracks: {
			extra: { mode: "snapshot" },
		},
	},
};

export async function catalog(url: URL): Promise<void> {
	const pub = handle(url);
	const sub = handle(url);
	try {
		const pubOrigin = await connected(pub);
		const subOrigin = await connected(sub);
		const announced = sub.announced();

		const broadcast = pubOrigin.createBroadcast(Moq.Path.from(PATH));
		const track = broadcast.createTrack(Catalog.TRACK);
		const producer = new Json.Snapshot.Producer<Catalog.Root>({
			track,
			schema: Catalog.RootSchema,
			deltaRatio: 100,
		});
		broadcast.announce();

		await waitAnnounce(announced, PATH, true);
		const request = subOrigin.request(Moq.Path.from(PATH));
		const consumer = await waitActive(request, "catalog broadcast");

		const snapshot = new Json.Snapshot.Consumer<Catalog.Root>({
			track: consumer.track(Catalog.TRACK).subscribe({
				priority: Catalog.PRIORITY.catalog,
				maxAge: REPLAY_MS,
			}),
			schema: Catalog.RootSchema,
		});

		producer.update(SNAPSHOT);
		const first = await snapshot.next();
		if (!first || !equal(first, SNAPSHOT)) {
			throw new Error(`first catalog was ${JSON.stringify(first)}`);
		}

		producer.update(UPDATED);
		const second = await snapshot.next();
		if (!second || !equal(second, UPDATED)) {
			throw new Error(`delta did not reconstruct ${JSON.stringify(second)}`);
		}

		producer.finish();

		const raw = consumer
			.track(Catalog.TRACK)
			.subscribe({ priority: Catalog.PRIORITY.catalog, maxAge: REPLAY_MS })
			.ordered();
		const group = await raw.nextGroup();
		if (!group) throw new Error("catalog group missing");
		const frames: Uint8Array[] = [];
		for (;;) {
			const frame = await group.readFrame();
			if (!frame) break;
			frames.push(frame.payload);
		}
		if (frames.length < 2) {
			throw new Error(`expected a snapshot frame then a delta, got ${frames.length} frame(s)`);
		}

		const decoder = new TextDecoder();
		const root = Catalog.RootSchema.parse(JSON.parse(decoder.decode(frames[0])));
		if (!equal(root, SNAPSHOT)) throw new Error("frame 0 was not the full catalog snapshot");

		let deltaParsedAsCatalog = false;
		try {
			Catalog.RootSchema.parse(JSON.parse(decoder.decode(frames[1])));
			deltaParsedAsCatalog = true;
		} catch {
			// The delta is an RFC 7396 merge patch, not a catalog root.
		}
		if (deltaParsedAsCatalog) {
			throw new Error("frame 1 parsed as a full catalog; the consumer is not reconstructing deltas");
		}
	} finally {
		pub.close();
		sub.close();
	}
	console.log("  catalog: ok");
}
