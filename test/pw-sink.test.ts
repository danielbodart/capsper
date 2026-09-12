import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { $, spawn } from "bun";
import { writeFileSync, readFileSync, unlinkSync, mkdirSync, rmSync, readdirSync, statSync } from "fs";
import { join } from "path";
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
 * Mean dBFS of one channel of a stereo file, narrowed to a band around `hz`.
 *
 * Narrowed because the comparison that matters is "is this particular tone
 * here?", and a broadband level would be dominated by whatever else the
 * microphone picked up.
 */
async function bandDb(path: string, channel: 0 | 1, hz: number): Promise<number> {
    const pan = channel === 0 ? "pan=mono|c0=c0" : "pan=mono|c0=c1";
    const { stderr } = await $`ffmpeg -i ${path} -af ${`${pan},bandpass=f=${hz}:width_type=h:w=40,volumedetect`} -f null - `
        .quiet()
        .nothrow();
    const match = stderr.toString().match(/mean_volume:\s*(-?[\d.]+) dB/);
    return match ? parseFloat(match[1]) : -Infinity;
}

/** Every session audio file under a sessions root, oldest path first. */
function walkWavs(dir: string, found: string[] = []): string[] {
    for (const entry of readdirSync(dir)) {
        const path = join(dir, entry);
        if (statSync(path).isDirectory()) walkWavs(path, found);
        else if (entry.endsWith(".wav")) found.push(path);
    }
    return found;
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
    let sessionsDir = "";
    let server: ReturnType<typeof spawn> | undefined;
    let objects: any[] = [];

    beforeAll(async () => {
        ensureBinary();

        configFile = tmpFile("capsper-sink-config", ".zon");
        // A sessions directory of its own, so a test run never writes into the
        // recordings a real install is keeping.
        sessionsDir = tmpFile("capsper-sessions", "");
        mkdirSync(sessionsDir, { recursive: true });
        // A three-second idle window rather than the thirty a real meeting
        // wants: the debounce arithmetic is unit-tested in meeting.zig, so
        // what this has to show is that the graph drives it at all.
        writeFileSync(
            configFile,
            `.{ .meeting = .{ .enabled = true, .sink_name = "${SINK}",` +
                ` .idle_close_seconds = 3, .dir = "${sessionsDir}" } }\n`,
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
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    const count = (needle: string) =>
        readFileSync(logFile, "utf8").split(needle).length - 1;

    const sessionFiles = () => walkWavs(sessionsDir).sort();

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

    test("writes one stereo session file into a dated directory", async () => {
        const files = sessionFiles();
        expect(files.length).toBeGreaterThan(0);

        // `YYYY/MM/DD/THHMMSSZ/audio.wav` relative to the sessions root: one
        // ISO timestamp split across directories, so it sorts at every level.
        const relative = files[0].slice(sessionsDir.length + 1);
        expect(relative).toMatch(/^\d{4}\/\d{2}\/\d{2}\/T\d{6}Z\/audio\.wav$/);

        const probe = await $`ffprobe -v error -show_entries stream=channels,sample_rate -of default=noprint_wrappers=1 ${files[0]}`
            .quiet()
            .nothrow();
        expect(probe.stdout.toString()).toContain("channels=2");
        expect(probe.stdout.toString()).toContain("sample_rate=16000");
    });

    test("puts the call on the right channel and the microphone on the left", async () => {
        // The failure this is really guarding against is the far track being a
        // second copy of the near one, which is what happens if the capture
        // stream misses `stream.capture.sink` and silently falls back to the
        // default source. Both channels would carry audio and look fine.
        //
        // So it is measured in the tone's own narrow band rather than overall:
        // the tone was played into the sink and exists nowhere else, so it has
        // to be much stronger on the right than on the left.
        await settle();
        const before = sessionFiles().length;

        const loud = tmpFile("capsper-sink-loud", ".wav");
        await $`ffmpeg -y -f lavfi -i sine=frequency=880:duration=3:sample_rate=48000 -af volume=-20dB -ac 2 ${loud}`
            .quiet()
            .nothrow();

        const play = spawn(["pw-play", "--target", SINK, loud], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(play);
        await play.exited;
        await Bun.sleep(5000); // let the idle window close the session

        const files = sessionFiles();
        expect(files.length).toBe(before + 1);
        const audio = files[files.length - 1];

        const left = await bandDb(audio, 0, 880);
        const right = await bandDb(audio, 1, 880);
        console.error(`  880Hz band — left: ${left} dBFS, right: ${right} dBFS`);

        // The tone is on the right. A far track that was secretly the
        // microphone would put these within a few dB of each other.
        expect(right).toBeGreaterThan(left + 10);

        try { unlinkSync(loud); } catch {}
    }, 60_000);

    test("transcribes the call into a WebVTT file beside the audio", async () => {
        await settle();

        // Real speech rather than a tone, because a tone transcribes to
        // nothing. Resampled to what the sink expects.
        const speech = tmpFile("capsper-sink-speech", ".wav");
        await $`ffmpeg -y -i test/jfk.wav -ar 48000 -ac 2 ${speech}`.quiet().nothrow();

        const play = spawn(["pw-play", "--target", SINK, speech], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(play);
        await play.exited;
        await Bun.sleep(5000);

        const dir = sessionFiles().pop()!.replace(/audio\.wav$/, "");
        const vtt = readFileSync(join(dir, "transcript.vtt"), "utf8");
        console.error(vtt.split("\n").slice(0, 12).join("\n"));

        expect(vtt.startsWith("WEBVTT\n")).toBe(true);
        // The channel assignment travels with the recording, so a session
        // found in two years says which side is which.
        expect(vtt).toContain("near end (microphone) = left");

        // The speech played into the sink is the far end, and it is attributed
        // as such rather than guessed at by diarisation.
        expect(vtt).toContain("<v Far>");
        expect(vtt.toLowerCase()).toContain("my fellow americans");

        // Start times must not decrease: cues complete when their own track
        // goes quiet, so they finish out of order and have to be merged.
        const starts = [...vtt.matchAll(/^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) --> /gm)].map(
            (m) => ((+m[1] * 60 + +m[2]) * 60 + +m[3]) * 1000 + +m[4],
        );
        expect(starts.length).toBeGreaterThan(0);
        expect([...starts].sort((a, b) => a - b)).toEqual(starts);

        try { unlinkSync(speech); } catch {}
    }, 90_000);

    test("keeps cue timestamps in step with the recording across a long silence", async () => {
        // The trap this guards against does not exist yet, and that is the
        // point of writing it now. Cue positions are counted as audio
        // arrives, ahead of the encoder. Today everything that arrives is
        // encoded, so the two agree and this passes trivially.
        //
        // The moment a VAD sits in front of the encoder to stop paying for
        // silence, they diverge: a position derived from what the encoder
        // consumed would skip the elided silence, so every cue after the
        // first pause drifts earlier by the total silence skipped. On an
        // hour-long meeting the end would be minutes out, and nothing about
        // the file would look wrong.
        await settle();

        // Speech, then ten seconds of nothing, then the same speech again.
        const gapped = tmpFile("capsper-sink-gapped", ".wav");
        await $`ffmpeg -y -i test/jfk.wav -i test/jfk.wav -filter_complex ${"[0:a]apad=pad_dur=10[a];[a][1:a]concat=n=2:v=0:a=1"} -ar 48000 -ac 2 ${gapped}`
            .quiet()
            .nothrow();

        const probe = await $`ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 ${gapped}`
            .quiet()
            .nothrow();
        const durationMs = parseFloat(probe.stdout.toString()) * 1000;

        const play = spawn(["pw-play", "--target", SINK, gapped], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(play);
        await play.exited;
        await Bun.sleep(5000);

        const dir = sessionFiles().pop()!.replace(/audio\.wav$/, "");
        const vtt = readFileSync(join(dir, "transcript.vtt"), "utf8");

        const cues = [...vtt.matchAll(/^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) --> (\d{2}):(\d{2}):(\d{2})\.(\d{3})$/gm)].map(
            (m) => ({
                start: ((+m[1] * 60 + +m[2]) * 60 + +m[3]) * 1000 + +m[4],
                end: ((+m[5] * 60 + +m[6]) * 60 + +m[7]) * 1000 + +m[8],
            }),
        );
        expect(cues.length).toBeGreaterThan(1);

        const lastEnd = Math.max(...cues.map((c) => c.end));
        console.error(`  played ${(durationMs / 1000).toFixed(1)}s, last cue ends at ${(lastEnd / 1000).toFixed(1)}s`);

        // The second half of the speech has to be attributed after the
        // silence, not folded back onto the first half.
        const lastStart = Math.max(...cues.map((c) => c.start));
        expect(lastStart).toBeGreaterThan(15_000);

        // And the transcript must not run past the recording it describes.
        expect(lastEnd).toBeLessThanOrEqual(durationMs + 2000);

        try { unlinkSync(gapped); } catch {}
    }, 120_000);

    test("is gone once capsper exits", async () => {
        try { server?.kill(); } catch {}
        await Bun.sleep(1500);

        const after = nodes(await dump()).filter((n) => n.name.startsWith(SINK));
        expect(after).toHaveLength(0);
    });
});
