import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { $, spawn } from "bun";
import { writeFileSync, readFileSync, unlinkSync } from "fs";
import { BINARY, ensureBinary, tmpFile, trackProc, waitForLog } from "./helpers";

const isLinux = process.platform === "linux";

// Named for this test so a stray node from a crashed run is obvious, and can
// never be mistaken for the real `capsper_call` a user is running.
const SINK = "test_capsper_sink";

interface Node {
    id: number;
    name: string;
    mediaClass: string;
    state: string;
}

async function dump(): Promise<any[]> {
    const { stdout, exitCode } = await $`pw-dump`.quiet().nothrow();
    if (exitCode !== 0) return [];
    try {
        return JSON.parse(stdout.toString());
    } catch {
        return [];
    }
}

function nodes(objects: any[]): Node[] {
    return objects
        .filter((o) => o.type === "PipeWire:Interface:Node" && o.info?.props)
        .map((o) => ({
            id: o.id,
            name: o.info.props["node.name"] ?? "",
            mediaClass: o.info.props["media.class"] ?? "",
            state: o.info.state ?? "",
        }));
}

/** The node ids a given node's output ports are linked into. */
function linkTargets(objects: any[], from: number): number[] {
    return objects
        .filter((o) => o.type === "PipeWire:Interface:Link" && o.info?.["output-node-id"] === from)
        .map((o) => o.info["input-node-id"]);
}

function defaultSinkName(objects: any[]): string | undefined {
    for (const o of objects) {
        if (o.type !== "PipeWire:Interface:Metadata") continue;
        for (const entry of o.metadata ?? []) {
            if (entry.key === "default.audio.sink") return entry.value?.name;
        }
    }
    return undefined;
}

/** Peak dBFS of a WAV, via ffmpeg's volumedetect. -91 or so means silence. */
async function peakDb(path: string): Promise<number> {
    const { stderr } = await $`ffmpeg -i ${path} -af volumedetect -f null - `.quiet().nothrow();
    const match = stderr.toString().match(/max_volume:\s*(-?[\d.]+) dB/);
    return match ? parseFloat(match[1]) : -Infinity;
}

/**
 * Record the sink's monitor, optionally playing a file into the sink partway
 * through, and return the peak level of what the monitor carried.
 *
 * `stream.capture.sink` is the part that matters: it is what makes a capture
 * stream attach to a sink's monitor ports rather than to a source.
 */
async function recordMonitor(leadInMs: number, play: string | null): Promise<number> {
    const recorded = tmpFile("capsper-sink-monitor", ".wav");

    const rec = spawn(
        ["pw-record", "-P", "{ stream.capture.sink=true }", "--target", SINK, recorded],
        { stdout: "ignore", stderr: "ignore" },
    );
    trackProc(rec);
    await Bun.sleep(leadInMs);

    if (play) {
        const player = spawn(["pw-play", "--target", SINK, play], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(player);
        await player.exited;
    }
    await Bun.sleep(500);

    try { rec.kill(); } catch {}
    await Bun.sleep(500);

    const peak = await peakDb(recorded);
    try { unlinkSync(recorded); } catch {}
    return peak;
}

describe.skipIf(!isLinux)("virtual sink", () => {
    let configFile = "";
    let toneFile = "";
    let logFile = "";
    let server: ReturnType<typeof spawn> | undefined;
    let objects: any[] = [];

    beforeAll(async () => {
        ensureBinary();

        configFile = tmpFile("capsper-sink-config", ".zon");
        // A three-second idle window rather than the thirty a real meeting
        // wants: the debounce arithmetic is unit-tested in meeting.zig, so
        // what this has to show is that the graph drives it at all.
        writeFileSync(
            configFile,
            `.{ .meeting = .{ .enabled = true, .sink_name = "${SINK}", .idle_close_seconds = 3 } }\n`,
        );

        // Quiet enough not to be alarming if the machine's speakers are live:
        // the pass-through is a real path to the real output, which is the
        // whole point of the test.
        toneFile = tmpFile("capsper-sink-tone", ".wav");
        await $`ffmpeg -y -f lavfi -i sine=frequency=440:duration=1:sample_rate=48000 -af volume=-40dB -ac 2 ${toneFile}`.quiet().nothrow();

        logFile = tmpFile("capsper-sink", ".log");
        server = spawn([BINARY, "--config", configFile], {
            stdout: "ignore",
            stderr: Bun.file(logFile),
        });
        trackProc(server);

        // 180s: the model still loads before the process settles, and a first
        // CUDA run compiles PTX.
        await waitForLog(logFile, new RegExp(`Virtual sink '${SINK}' ready`), server, 180);
        await Bun.sleep(1000); // let the module's nodes reach the daemon
        objects = await dump();
    });

    afterAll(async () => {
        try { server?.kill(); } catch {}
        await Bun.sleep(1000);
        for (const path of [configFile, toneFile]) {
            try { unlinkSync(path); } catch {}
        }
    });

    const count = (needle: string) =>
        readFileSync(logFile, "utf8").split(needle).length - 1;

    /** Wait until no session is open, so a count-based assertion starts level. */
    async function settle(): Promise<void> {
        for (let i = 0; i < 20; i++) {
            if (count("session opened") === count("session closed")) return;
            await Bun.sleep(1000);
        }
        throw new Error("a meeting session never closed");
    }

    test("appears in the graph as a sink", () => {
        const sink = nodes(objects).find((n) => n.name === SINK);
        expect(sink).toBeDefined();
        // Audio/Sink is what puts it in the desktop's output picker.
        expect(sink!.mediaClass).toBe("Audio/Sink");
    });

    test("sits suspended while nothing is playing into it", () => {
        // Not merely tidy: an idle sink is what lets the graph answer "is a
        // call happening?" rather than being permanently busy.
        const sink = nodes(objects).find((n) => n.name === SINK);
        expect(sink!.state).toBe("suspended");
    });

    test("passes through to the default output, so the call stays audible", () => {
        const passthrough = nodes(objects).find((n) => n.name === `${SINK}.passthrough`);
        expect(passthrough).toBeDefined();

        const targets = linkTargets(objects, passthrough!.id);
        expect(targets.length).toBeGreaterThan(0);

        const byId = new Map(nodes(objects).map((n) => [n.id, n]));
        const reached = targets.map((id) => byId.get(id)?.name);
        expect(reached).toContain(defaultSinkName(objects));
    });

    test("its monitor is silent until something plays, then carries it", async () => {
        // Both halves matter. `pw-record --target NAME` on its own attaches to
        // the default *source* -- the microphone -- and happily returns room
        // noise, which would pass a "there is audio" assertion without the
        // monitor being involved at all. `stream.capture.sink` is what asks
        // for the monitor, and the silent reading is what proves we got it.
        const idle = await recordMonitor(1500, null);
        console.error(`  monitor idle peak:    ${idle} dBFS`);
        expect(idle).toBeLessThan(-80);

        const playing = await recordMonitor(500, toneFile);
        console.error(`  monitor playing peak: ${playing} dBFS`);
        expect(playing).toBeGreaterThan(idle + 20);
    }, 30_000);

    test("opens a session when something plays, and closes it when that stops", async () => {
        // Gate 1 end to end: the user selecting the sink in a meeting app is
        // what says a call is happening, and this is that signal arriving.
        //
        // Counted rather than matched, because the monitor test above plays
        // into the same sink and so opens a session of its own. That the gate
        // fired for a test that was not trying to trigger it is the point
        // working, not interference -- but it does mean this cannot assume it
        // starts from nothing.
        await settle();
        const openedBefore = count("session opened");
        const closedBefore = count("session closed");

        const play = spawn(["pw-play", "--target", SINK, toneFile], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(play);
        await play.exited;
        await Bun.sleep(1500);

        expect(count("session opened")).toBe(openedBefore + 1);
        // Still inside the three-second window, so a brief gap has not ended it.
        expect(count("session closed")).toBe(closedBefore);

        await Bun.sleep(5000);
        expect(count("session closed")).toBe(closedBefore + 1);

        // The session is named for when it started, as a path that sorts.
        const opened = readFileSync(logFile, "utf8").match(/session opened: (\S+)/);
        expect(opened).not.toBeNull();
        expect(opened![1]).toMatch(/^\d{4}\/\d{2}\/\d{2}\/T\d{6}Z$/);
    }, 60_000);

    test("is gone once capsper exits", async () => {
        try { server?.kill(); } catch {}
        await Bun.sleep(1500);

        const after = nodes(await dump()).filter((n) => n.name.startsWith(SINK));
        expect(after).toHaveLength(0);
    });
});
