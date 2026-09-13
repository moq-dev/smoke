// Stats snapshots versus retained rollup groups.
// Live counters are a lossy latest-value Snapshot. Billing rollups are a Window:
// a late joiner still sees the retained buckets, and pops drop the front.
import * as Json from "@moq/json";
import * as Moq from "@moq/net";
import { connected, handle, REPLAY_MS, waitActive, waitAnnounce } from "./lib.ts";

const PATH = "dev.stats";

type Snapshot = { bytes: number };
type Bucket = { start: number; bytes: number };

function pushedBytes(event: Json.Window.Event<Bucket> | undefined): number | undefined {
	return event && "push" in event ? event.push.value.bytes : undefined;
}

export async function stats(url: URL): Promise<void> {
	const pub = handle(url);
	const sub = handle(url);
	try {
		const pubOrigin = await connected(pub);
		const subOrigin = await connected(sub);
		const announced = sub.announced();

		const broadcast = pubOrigin.createBroadcast(Moq.Path.from(PATH));
		const liveTrack = broadcast.createTrack("live.json");
		const rollupTrack = broadcast.createTrack("minute");
		const live = new Json.Snapshot.Producer<Snapshot>({ track: liveTrack, deltaRatio: 100 });
		const rollup = new Json.Window.Producer<Bucket>({ track: rollupTrack });
		broadcast.announce();

		await waitAnnounce(announced, PATH, true);
		const request = subOrigin.request(Moq.Path.from(PATH));
		const consumer = await waitActive(request, "stats broadcast");

		const liveReader = new Json.Snapshot.Consumer<Snapshot>({
			track: consumer.track("live.json").subscribe({ priority: 0, maxAge: REPLAY_MS }),
		});
		const rollupReader = new Json.Window.Consumer<Bucket>({
			track: consumer.track("minute").subscribe({ priority: 0, maxAge: REPLAY_MS }),
		});

		live.update({ bytes: 1 });
		const firstLive = await liveReader.next();
		if (firstLive?.bytes !== 1) throw new Error(`live snapshot 1: ${JSON.stringify(firstLive)}`);

		live.update({ bytes: 2 });
		const secondLive = await liveReader.next();
		if (secondLive?.bytes !== 2) throw new Error(`live snapshot 2: ${JSON.stringify(secondLive)}`);

		rollup.push({ start: 0, bytes: 10 });
		const push0 = await rollupReader.next();
		if (!push0 || !("push" in push0) || push0.push.value.bytes !== 10) {
			throw new Error(`rollup push 0: ${JSON.stringify(push0)}`);
		}

		rollup.push({ start: 1, bytes: 20 });
		const push1 = await rollupReader.next();
		if (!push1 || !("push" in push1) || push1.push.index !== 1) {
			throw new Error(`rollup push 1: ${JSON.stringify(push1)}`);
		}

		rollup.pop(1);
		const pop = await rollupReader.next();
		if (!pop || !("pop" in pop) || pop.pop.start !== 0 || pop.pop.end !== 1) {
			throw new Error(`rollup pop: ${JSON.stringify(pop)}`);
		}

		// A late snapshot joiner collapses to the latest value. A late window
		// joiner is restated the retained suffix, not only the live tail.
		const lateLive = new Json.Snapshot.Consumer<Snapshot>({
			track: consumer.track("live.json").subscribe({ priority: 0, maxAge: REPLAY_MS }),
		});
		const lateLiveValue = await lateLive.next();
		if (lateLiveValue?.bytes !== 2) {
			throw new Error(`late snapshot joiner: ${JSON.stringify(lateLiveValue)}`);
		}

		const lateRollup = new Json.Window.Consumer<Bucket>({
			track: consumer.track("minute").subscribe({ priority: 0, maxAge: REPLAY_MS }),
		});
		const first = await lateRollup.next();
		const second = pushedBytes(first) === 20 ? first : await lateRollup.next();
		if (pushedBytes(first) !== 20 && pushedBytes(second) !== 20) {
			throw new Error(`late window joiner never saw the retained bucket: ${JSON.stringify([first, second])}`);
		}

		live.finish();
		rollup.finish();
	} finally {
		pub.close();
		sub.close();
	}
	console.log("  stats: ok");
}
