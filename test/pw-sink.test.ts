import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { $, spawn } from "bun";
import { writeFileSync, readFileSync, unlinkSync, mkdirSync, rmSync, readdirSync, statSync, existsSync } from "fs";
import { join } from "path";
import { connect } from "net";
import { BINARY, ensureBinary, tmpFile, trackProc, waitForLog, until, createNullSink, removeNullSink } from "./helpers";

const isLinux = process.platform === "linux";

// Playing audio through the sink is the only way to exercise capture, and it
// takes real time to do it -- a ten-second recording takes ten seconds. Those
// tests are opt-in; the rest run in a couple of seconds and play nothing.
const SLOW = !!process.env.SLOW_TESTS;

// Named for this test so a stray node from a crashed run is obvious, and can
// never be mistaken for the real `capsper_transcribe` a user is running.
const SINK = "test_capsper_sink";
const AUDIO_SINK = "test_capsper_audio_sink";

// Off the defaults, so a test run never collides with a capsper the user is
// actually running.
const HTTP_PORT = 43918;
const AUDIO_HTTP_PORT = 43919;

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

// Where the pass-through sends the call during a test: a sink of the test's
// own that goes nowhere, named per block so two blocks cannot collide.
//
// This replaced muting the pass-through. Muting stopped the sound but left the
// sink wired to the machine's real speakers, which meant it could only reach
// `suspended` when nothing else was using them -- so "sits suspended while
// nothing is playing" failed whenever someone had music on. Owning the
// destination makes the sound impossible rather than merely inaudible, and
// makes the idle state depend on nothing outside the test.
const OUTPUT_SINKS = {
    graph: "test_capsper_out_graph",
    capture: "test_capsper_out_capture",
    opus: "test_capsper_out_opus",
};

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

/**
 * Peak dBFS of one channel of a stereo file, narrowed to a band around `hz`.
 *
 * Peak rather than mean, for anything comparing a recording against the signal
 * that went in. A mean is dragged down by however much of the recording is
 * silence, which depends on when a session happened to open and close; a peak
 * is the same number whether the tone ran for half the file or all of it.
 */
async function bandPeakDb(path: string, channel: 0 | 1, hz: number): Promise<number> {
    const pan = channel === 0 ? "pan=mono|c0=c0" : "pan=mono|c0=c1";
    const { stderr } = await $`ffmpeg -i ${path} -af ${`${pan},bandpass=f=${hz}:width_type=h:w=40,volumedetect`} -f null - `
        .quiet()
        .nothrow();
    const match = stderr.toString().match(/max_volume:\s*(-?[\d.]+) dB/);
    return match ? parseFloat(match[1]) : -Infinity;
}

/** Every session audio file of the given extension under a sessions root. */
function walkAudio(dir: string, ext: string, found: string[] = []): string[] {
    for (const entry of readdirSync(dir)) {
        const path = join(dir, entry);
        if (statSync(path).isDirectory()) walkAudio(path, ext, found);
        else if (entry.endsWith(ext)) found.push(path);
    }
    return found;
}

/** Start capsper with meeting capture on, and wait for the sink to come up. */
async function startCapsper(opts: {
    sink: string;
    output: string;
    sessionsDir: string;
    httpPort: number;
    idleCloseSeconds: number;
    audioFormat?: "wav" | "opus";
    /** Node the near track captures from, instead of the desktop's input. */
    near?: string;
    /** Starting capture gain, as `--audio-detect` would have measured one. */
    gain?: number;
    /** Off makes a recorded level depend on `gain` alone, not on a loop. */
    autoGain?: boolean;
    /** Off keeps the near capture on `near` rather than the cleaned node. */
    aec?: boolean;
    /** Capture channel. MONO for a mono virtual source. */
    channel?: "MONO" | "FL" | "FR";
}) {
    const configFile = tmpFile("capsper-sink-config", ".zon");
    const audio =
        opts.gain === undefined && opts.autoGain === undefined
            ? ""
            : ` .audio = .{ .gain = ${(opts.gain ?? 1).toFixed(1)},` +
              ` .auto_gain = ${opts.autoGain ?? true},` +
              ` .channel = .${opts.channel ?? "FL"} },`;
    writeFileSync(
        configFile,
        `.{${audio} .meeting = .{ .enabled = true, .sink_name = "${opts.sink}",` +
            ` .output = "${opts.output}",` +
            (opts.near ? ` .near = "${opts.near}",` : "") +
            ` .idle_close_seconds = ${opts.idleCloseSeconds}, .dir = "${opts.sessionsDir}",` +
            ` .audio_format = .${opts.audioFormat ?? "opus"},` +
            (opts.aec === undefined ? "" : ` .aec = .{ .enabled = ${opts.aec} },`) +
            ` .http = .{ .port = ${opts.httpPort} } } }\n`,
    );

    const logFile = tmpFile("capsper-sink", ".log");
    const proc = spawn([BINARY, "--config", configFile], {
        stdout: "ignore",
        stderr: Bun.file(logFile),
    });
    trackProc(proc);

    // 180s: the model still loads before the process settles, and a first CUDA
    // run compiles PTX.
    await waitForLog(logFile, new RegExp(`Virtual sink '${opts.sink}' ready`), proc, 180);

    // "Ready" and "visible in the graph" are not the same instant: the module
    // creates its nodes on its own loop.
    await until(`${opts.sink} to reach the graph`, async () =>
        nodes(await dump()).some((n) => n.name === `${opts.sink}.passthrough`));

    // The server binds before the sink is announced, but wait for it rather
    // than assume the ordering.
    await until(`the session server on ${opts.httpPort}`, async () =>
        (await fetch(`http://127.0.0.1:${opts.httpPort}/sessions.json`)).ok);

    return { proc, configFile, logFile };
}

/** Wait for a process to be gone, so cleanup does not race the next test. */
async function waitForExit(proc: ReturnType<typeof spawn>): Promise<void> {
    try { proc.kill(); } catch {}
    await until("capsper to exit", () => proc.exitCode !== null || proc.signalCode !== null);
}

// ─── The graph and the server, playing nothing ───────────────────────────────

describe.skipIf(!isLinux)("virtual sink", () => {
    let capsper: Awaited<ReturnType<typeof startCapsper>>;
    let sessionsDir = "";
    let objects: any[] = [];

    // A session written straight to disk, so the server has something real to
    // serve without a recording having to be made in real time first.
    const SESSION = "2026/09/11/T143000Z";

    let outputModule = "";

    beforeAll(async () => {
        ensureBinary();
        outputModule = await createNullSink(OUTPUT_SINKS.graph);

        sessionsDir = tmpFile("capsper-sessions", "");
        mkdirSync(join(sessionsDir, SESSION), { recursive: true });
        await $`ffmpeg -y -f lavfi -i ${"sine=frequency=440:duration=2:sample_rate=16000"} -ac 2 -c:a pcm_s16le ${join(sessionsDir, SESSION, "audio.wav")}`
            .quiet()
            .nothrow();
        writeFileSync(
            join(sessionsDir, SESSION, "audio.vtt"),
            "WEBVTT\n\nNOTE capsper meeting transcript\n\n1\n00:00:00.500 --> 00:00:01.500\n<v Far>hello there\n",
        );

        capsper = await startCapsper({
            sink: SINK,
            output: OUTPUT_SINKS.graph,
            sessionsDir,
            httpPort: HTTP_PORT,
            idleCloseSeconds: 3,
        });
        objects = await dump();
    }, 240_000);

    afterAll(async () => {
        if (capsper) await waitForExit(capsper.proc);
        for (const path of [capsper?.configFile, capsper?.logFile]) {
            if (path) try { unlinkSync(path); } catch {}
        }
        await removeNullSink(outputModule);
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    test("appears in the graph as a sink", () => {
        const sink = nodes(objects).find((n) => n.name === SINK);
        expect(sink).toBeDefined();
        // Audio/Sink is what puts it in the desktop's output picker.
        expect(sink!.mediaClass).toBe("Audio/Sink");
    });

    test("sits suspended while nothing is playing into it", () => {
        // Not merely tidy: an idle sink is what lets the graph answer "is a
        // call happening?" rather than being permanently busy.
        //
        // Only reliable because `meeting.output` points this sink at one the
        // test owns. Following the desktop's default output instead, the sink
        // cannot suspend while anything else on the machine is using the
        // speakers, and this fails whenever someone has music on.
        const sink = nodes(objects).find((n) => n.name === SINK);
        expect(sink!.state).toBe("suspended");
    });

    test("passes the call on to the configured output, so it stays audible", () => {
        // The destination here is the test's own null sink, named by
        // `meeting.output`. With that unset -- the shipped default, and what a
        // real user runs -- the same link reaches whatever the desktop's
        // output is instead. Asserting against a sink the test owns is what
        // keeps this from depending on the machine it runs on.
        const passthrough = nodes(objects).find((n) => n.name === `${SINK}.passthrough`);
        expect(passthrough).toBeDefined();

        const targets = linkTargets(objects, passthrough!.id);
        expect(targets.length).toBeGreaterThan(0);

        const byId = new Map(nodes(objects).map((n) => [n.id, n]));
        const reached = targets.map((id) => byId.get(id)?.name);
        expect(reached).toContain(OUTPUT_SINKS.graph);
    });

    test("its monitor reads as digital silence while nothing is playing", async () => {
        // `pw-record --target NAME` on its own attaches to the default
        // *source* -- the microphone -- and happily returns room noise.
        // `stream.capture.sink` is what asks for the monitor instead, and a
        // reading of pure silence is what proves we got it.
        const recorded = tmpFile("capsper-sink-monitor", ".wav");
        const rec = spawn(
            ["pw-record", "-P", "{ stream.capture.sink=true }", "--target", SINK, recorded],
            { stdout: "ignore", stderr: "ignore" },
        );
        trackProc(rec);

        // Enough captured audio to judge, rather than a guess at how long that
        // takes: a second of 16-bit stereo at 48 kHz is comfortably past this.
        await until("the monitor to record something", () => statSync(recorded).size > 64_000);
        try { rec.kill(); } catch {}
        await until("the recording to be flushed", () => statSync(recorded).size > 64_000);

        const peak = await peakDb(recorded);
        console.error(`  monitor idle peak: ${peak} dBFS`);
        expect(peak).toBeLessThan(-80);

        try { unlinkSync(recorded); } catch {}
    }, 30_000);

    test("serves the sessions directory", async () => {
        const base = `http://127.0.0.1:${HTTP_PORT}`;

        const index = await fetch(`${base}/`);
        expect(index.status).toBe(200);
        expect(index.headers.get("content-type")).toContain("text/html");

        const listing = await fetch(`${base}/sessions.json`);
        expect(listing.status).toBe(200);
        const sessions = await listing.json();

        expect(sessions.map((s: any) => s.path)).toContain(SESSION);
        const found = sessions.find((s: any) => s.path === SESSION);
        expect(found.audio).toBe("audio.wav");
        expect(found.seconds).toBeCloseTo(2, 0);
    });

    test("lists sessions newest first", async () => {
        // The dated layout gives this for free by sorting the paths
        // descending, which is one of the reasons the leaf is an ISO
        // timestamp.
        const older = "2026/09/10/T090000Z";
        mkdirSync(join(sessionsDir, older), { recursive: true });
        writeFileSync(join(sessionsDir, older, "audio.wav"), "");

        const sessions = await (await fetch(`http://127.0.0.1:${HTTP_PORT}/sessions.json`)).json();
        const paths = sessions.map((s: any) => s.path);
        expect(paths).toEqual([...paths].sort().reverse());
        expect(paths.indexOf(SESSION)).toBeLessThan(paths.indexOf(older));
    });

    test("serves both files of a session with the types a browser needs", async () => {
        const base = `http://127.0.0.1:${HTTP_PORT}/s/${SESSION}`;

        const audio = await fetch(`${base}/audio.wav`);
        expect(audio.status).toBe(200);
        expect(audio.headers.get("accept-ranges")).toBe("bytes");

        // A track element ignores a transcript served as anything but text/vtt.
        const vtt = await fetch(`${base}/audio.vtt`);
        expect(vtt.status).toBe(200);
        expect(vtt.headers.get("content-type")).toBe("text/vtt");
        expect(await vtt.text()).toContain("WEBVTT");
    });

    test("serves byte ranges, so a browser can seek without downloading it all", async () => {
        const url = `http://127.0.0.1:${HTTP_PORT}/s/${SESSION}/audio.wav`;

        const part = await fetch(url, { headers: { Range: "bytes=1000-1999" } });
        expect(part.status).toBe(206);
        expect((await part.arrayBuffer()).byteLength).toBe(1000);
        expect(part.headers.get("content-range")).toMatch(/^bytes 1000-1999\/\d+$/);
    });

    test("refuses a path that climbs out of the sessions directory", async () => {
        // `fetch` normalises `..` away before sending, so this has to go out as
        // a raw request to be testing anything at all.
        const raw = await new Promise<string>((resolve, reject) => {
            const sock = connect(HTTP_PORT, "127.0.0.1", () => {
                sock.write("GET /s/../../../../etc/passwd HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
            });
            let data = "";
            sock.on("data", (d: Buffer) => { data += d.toString(); });
            sock.on("close", () => resolve(data));
            sock.on("error", reject);
        });
        expect(raw).toMatch(/^HTTP\/1\.1 403/);
        expect(raw).not.toContain("root:");
    });

    test("is reachable on loopback but not from the network", async () => {
        // These are recordings of private conversations. Reaching them from
        // the network should take saying so in the config.
        const { stdout } = await $`ss -ltn`.quiet().nothrow();
        const line = stdout.toString().split("\n").find((l) => l.includes(`:${HTTP_PORT} `));
        expect(line).toBeDefined();
        expect(line).toContain("127.0.0.1");
        expect(line).not.toContain("0.0.0.0:" + HTTP_PORT);
    });

    test("is gone once capsper exits", async () => {
        await waitForExit(capsper.proc);

        const gone = await until("the sink to leave the graph", async () =>
            nodes(await dump()).filter((n) => n.name.startsWith(SINK)).length === 0);
        expect(gone).toBe(true);
    });
});

// ─── Capture, which needs audio actually played ──────────────────────────────

describe.skipIf(!isLinux || !SLOW)("virtual sink: capture", () => {
    let capsper: Awaited<ReturnType<typeof startCapsper>>;
    let sessionsDir = "";
    let speech = "";
    let gapped = "";
    let outputModule = "";

    beforeAll(async () => {
        ensureBinary();
        outputModule = await createNullSink(OUTPUT_SINKS.capture);
        sessionsDir = tmpFile("capsper-audio-sessions", "");
        mkdirSync(sessionsDir, { recursive: true });

        // Four seconds of real speech rather than the whole clip: these play in
        // real time, so every second of fixture is a second of test.
        speech = tmpFile("capsper-speech", ".wav");
        await $`ffmpeg -y -i test/jfk.wav -t 4 -ar 48000 -ac 2 ${speech}`.quiet().nothrow();

        // The same speech twice with a gap between, for the mid-session test.
        // jfk.wav has no pause long enough to close a cue on its own, and a
        // cue closes only when its track goes quiet -- so without a deliberate
        // gap the first cue would not exist until playback had already ended,
        // which is precisely the case the test is trying not to be.
        gapped = tmpFile("capsper-gapped-speech", ".wav");
        await $`ffmpeg -y -i test/jfk.wav -filter_complex ${
            "[0:a]atrim=0:4,asetpts=PTS-STARTPTS,apad=pad_dur=2.5[a];" +
            "[0:a]atrim=0:4,asetpts=PTS-STARTPTS[b];" +
            "[a][b]concat=n=2:v=0:a=1[out]"
        } -map ${"[out]"} -ar 48000 -ac 2 ${gapped}`.quiet().nothrow();

        capsper = await startCapsper({
            sink: AUDIO_SINK,
            output: OUTPUT_SINKS.capture,
            sessionsDir,
            httpPort: AUDIO_HTTP_PORT,
            idleCloseSeconds: 3,
            // WAV here, not the Opus a real session defaults to: these check
            // what the capture put in each channel, and raw samples make that
            // a direct measurement rather than one through a codec.
            audioFormat: "wav",
        });
    }, 240_000);

    afterAll(async () => {
        if (capsper) await waitForExit(capsper.proc);
        for (const path of [capsper?.configFile, capsper?.logFile, speech, gapped]) {
            if (path) try { unlinkSync(path); } catch {}
        }
        await removeNullSink(outputModule);
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    const count = (needle: string) =>
        readFileSync(capsper.logFile, "utf8").split(needle).length - 1;

    const sessionFiles = () => walkAudio(sessionsDir, ".wav").sort();

    /** Wait until no session is open, so a count-based assertion starts level. */
    const settle = () =>
        until("any open session to close", () => count("session opened") === count("session closed"), { timeoutSec: 30 });

    /** Wait for one more of `needle` than there were before. */
    const waitForOneMore = (needle: string, before: number) =>
        until(`another "${needle}"`, () => count(needle) === before + 1, { timeoutSec: 30 });

    /** Wait for one more session file than there were before. */
    const waitForNewSession = (before: number) =>
        until("a new session file", () => sessionFiles().length === before + 1, { timeoutSec: 30 });

    async function play(file: string): Promise<void> {
        const proc = spawn(["pw-play", "--target", AUDIO_SINK, file], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(proc);
        await proc.exited;
    }

    test("opens a session when something plays, and closes it when that stops", async () => {
        // Gate 1 end to end: the user selecting the sink in a meeting app is
        // what says a call is happening, and this is that signal arriving.
        await settle();
        const openedBefore = count("session opened");
        const closedBefore = count("session closed");

        await play(speech);

        await waitForOneMore("session opened", openedBefore);
        // Still inside the idle window, so a brief gap has not ended it.
        expect(count("session closed")).toBe(closedBefore);

        await waitForOneMore("session closed", closedBefore);

        // The session is named for when it started, as a path that sorts.
        const opened = readFileSync(capsper.logFile, "utf8").match(/session opened: (\S+)/);
        expect(opened![1]).toMatch(/^\d{4}\/\d{2}\/\d{2}\/T\d{6}Z$/);
    }, 60_000);

    test("writes one stereo session file into a dated directory", async () => {
        const files = sessionFiles();
        expect(files.length).toBeGreaterThan(0);

        const relative = files[0].slice(sessionsDir.length + 1);
        expect(relative).toMatch(/^\d{4}\/\d{2}\/\d{2}\/T\d{6}Z\/audio\.wav$/);

        const probe = await $`ffprobe -v error -show_entries stream=channels,sample_rate -of default=noprint_wrappers=1 ${files[0]}`
            .quiet()
            .nothrow();
        expect(probe.stdout.toString()).toContain("channels=2");
        expect(probe.stdout.toString()).toContain("sample_rate=16000");
    });

    test("puts the call on the right channel and the microphone on the left", async () => {
        // The failure this guards against is the far track being a second copy
        // of the near one, which is what happens if the capture stream misses
        // `stream.capture.sink` and falls back to the default source. Both
        // channels would carry audio and look fine.
        //
        // So it is measured in the tone's own narrow band rather than overall:
        // the tone was played into the sink and exists nowhere else.
        await settle();
        const before = sessionFiles().length;

        const tone = tmpFile("capsper-tone", ".wav");
        await $`ffmpeg -y -f lavfi -i ${"sine=frequency=880:duration=3:sample_rate=48000"} -af volume=-20dB -ac 2 ${tone}`
            .quiet()
            .nothrow();

        await play(tone);
        await waitForNewSession(before);

        const files = sessionFiles();
        const audio = files[files.length - 1];

        const left = await bandDb(audio, 0, 880);
        const right = await bandDb(audio, 1, 880);
        console.error(`  880Hz band — left: ${left} dBFS, right: ${right} dBFS`);
        expect(right).toBeGreaterThan(left + 10);

        try { unlinkSync(tone); } catch {}
    }, 60_000);

    test("makes the transcript readable while the session is still open", async () => {
        // A meeting is worth reading while it is happening, not only once it
        // has ended, so the transcript is rewritten every time a cue completes
        // rather than at close.
        await settle();
        const closedBefore = count("session closed");
        const filesBefore = sessionFiles().length;

        // Deliberately not awaited: the claim is about a session that is still
        // running, so the file has to be read while the audio is still playing.
        const playing = spawn(["pw-play", "--target", AUDIO_SINK, gapped], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(playing);

        await waitForNewSession(filesBefore);
        const vtt = sessionFiles().pop()!.replace(/audio\.wav$/, "audio.vtt");

        // The gap in the fixture closes the first cue, and the speech after it
        // keeps the session open while this looks.
        await until(
            "the transcript to appear mid-session",
            () => existsSync(vtt) && readFileSync(vtt, "utf8").includes(" --> "),
            { timeoutSec: 30 },
        );

        // The whole point: that happened before the session closed. Without
        // it, this file does not exist yet.
        expect(count("session closed")).toBe(closedBefore);

        const partial = readFileSync(vtt, "utf8");
        expect(partial.startsWith("WEBVTT\n")).toBe(true);
        expect(partial).toContain("<v Far>");

        await playing.exited;
    }, 120_000);

    test("transcribes the call into a WebVTT file beside the audio", async () => {
        await settle();
        const closedBefore = count("session closed");

        await play(speech);
        // Closing flushes the cue each track still had open, so the complete
        // transcript is the one written then.
        await waitForOneMore("session closed", closedBefore);

        const dir = sessionFiles().pop()!.replace(/audio\.wav$/, "");
        const vtt = readFileSync(join(dir, "audio.vtt"), "utf8");

        expect(vtt.startsWith("WEBVTT\n")).toBe(true);
        // The channel assignment travels with the recording, so a session found
        // in two years says which side is which.
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
    }, 90_000);

    test("keeps cue timestamps in step with the recording across a long silence", async () => {
        // The trap this guards against does not exist yet, and that is the
        // point of writing it now. Cue positions are counted as audio arrives,
        // ahead of the encoder. Today everything that arrives is encoded, so
        // the two agree and this passes trivially.
        //
        // The moment a VAD sits in front of the encoder, they diverge: a
        // position derived from what the encoder consumed would skip the
        // elided silence, so every cue after the first pause drifts earlier by
        // the total silence skipped. On an hour-long meeting the end would be
        // minutes out, and nothing about the file would look wrong.
        await settle();
        const closedBefore = count("session closed");

        const gapped = tmpFile("capsper-gapped", ".wav");
        await $`ffmpeg -y -i ${speech} -i ${speech} -filter_complex ${"[0:a]apad=pad_dur=6[a];[a][1:a]concat=n=2:v=0:a=1"} -ar 48000 -ac 2 ${gapped}`
            .quiet()
            .nothrow();

        const probe = await $`ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 ${gapped}`
            .quiet()
            .nothrow();
        const durationMs = parseFloat(probe.stdout.toString()) * 1000;

        await play(gapped);
        await waitForOneMore("session closed", closedBefore);

        const dir = sessionFiles().pop()!.replace(/audio\.wav$/, "");
        const vtt = readFileSync(join(dir, "audio.vtt"), "utf8");

        const cues = [...vtt.matchAll(/^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) --> (\d{2}):(\d{2}):(\d{2})\.(\d{3})$/gm)].map(
            (m) => ({
                start: ((+m[1] * 60 + +m[2]) * 60 + +m[3]) * 1000 + +m[4],
                end: ((+m[5] * 60 + +m[6]) * 60 + +m[7]) * 1000 + +m[8],
            }),
        );
        expect(cues.length).toBeGreaterThan(1);

        const lastStart = Math.max(...cues.map((c) => c.start));
        const lastEnd = Math.max(...cues.map((c) => c.end));
        console.error(`  played ${(durationMs / 1000).toFixed(1)}s, last cue ends at ${(lastEnd / 1000).toFixed(1)}s`);

        // The second half of the speech has to be attributed after the
        // silence, not folded back onto the first half.
        expect(lastStart).toBeGreaterThan(8000);
        // And the transcript must not run past the recording it describes.
        expect(lastEnd).toBeLessThanOrEqual(durationMs + 2000);

        try { unlinkSync(gapped); } catch {}
    }, 120_000);
});

// ─── The format a real session actually uses ─────────────────────────────────

describe.skipIf(!isLinux || !SLOW)("virtual sink: opus", () => {
    const OPUS_SINK = "test_capsper_opus_sink";
    const OPUS_HTTP_PORT = 43920;

    let capsper: Awaited<ReturnType<typeof startCapsper>>;
    let sessionsDir = "";
    let speech = "";
    let outputModule = "";

    beforeAll(async () => {
        ensureBinary();
        outputModule = await createNullSink(OUTPUT_SINKS.opus);
        sessionsDir = tmpFile("capsper-opus-sessions", "");
        mkdirSync(sessionsDir, { recursive: true });

        speech = tmpFile("capsper-opus-speech", ".wav");
        await $`ffmpeg -y -i test/jfk.wav -t 4 -ar 48000 -ac 2 ${speech}`.quiet().nothrow();

        capsper = await startCapsper({
            sink: OPUS_SINK,
            output: OUTPUT_SINKS.opus,
            sessionsDir,
            httpPort: OPUS_HTTP_PORT,
            idleCloseSeconds: 3,
            // The default, spelled out because it is the point of this block.
            audioFormat: "opus",
        });
    }, 240_000);

    afterAll(async () => {
        if (capsper) await waitForExit(capsper.proc);
        for (const path of [capsper?.configFile, capsper?.logFile, speech]) {
            if (path) try { unlinkSync(path); } catch {}
        }
        await removeNullSink(outputModule);
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    test("records a session as a playable Opus file", async () => {
        const count = (needle: string) =>
            readFileSync(capsper.logFile, "utf8").split(needle).length - 1;
        const closedBefore = count("session closed");

        const play = spawn(["pw-play", "--target", OPUS_SINK, speech], {
            stdout: "ignore",
            stderr: "ignore",
        });
        trackProc(play);
        await play.exited;
        await until("the session to close", () => count("session closed") === closedBefore + 1, {
            timeoutSec: 30,
        });

        const audio = walkAudio(sessionsDir, ".opus").sort().pop()!;
        expect(audio).toMatch(/\d{4}\/\d{2}\/\d{2}\/T\d{6}Z\/audio\.opus$/);

        // Readable by something that is not us, which is the only test of a
        // container format that means anything.
        const probe = await $`ffprobe -v error -show_entries stream=codec_name,channels -show_entries format=duration -of default=noprint_wrappers=1 ${audio}`
            .quiet()
            .nothrow();
        const info = probe.stdout.toString();
        expect(info).toContain("codec_name=opus");
        expect(info).toContain("channels=2");

        // Granule positions are counted at 48 kHz whatever the encoder was
        // given; get that wrong and the duration is out by a factor of three.
        const seconds = parseFloat(info.match(/duration=([\d.]+)/)![1]);
        expect(seconds).toBeGreaterThan(3);
        expect(seconds).toBeLessThan(15);

        // Far smaller than the WAV it came from, which is the reason for it.
        expect(statSync(audio).size).toBeLessThan(seconds * 64_000 / 4);

        // The transcript beside it shares the basename, so a player pairs them.
        const vtt = readFileSync(audio.replace(/\.opus$/, ".vtt"), "utf8");
        expect(vtt).toContain("audio.opus: near end");
    }, 90_000);

    test("serves the opus session with its duration and the right type", async () => {
        const sessions = await (await fetch(`http://127.0.0.1:${OPUS_HTTP_PORT}/sessions.json`)).json();
        expect(sessions.length).toBeGreaterThan(0);
        expect(sessions[0].audio).toBe("audio.opus");
        // Read back out of the last Ogg page's granule position.
        expect(sessions[0].seconds).toBeGreaterThan(3);

        const audio = await fetch(`http://127.0.0.1:${OPUS_HTTP_PORT}/s/${sessions[0].path}/audio.opus`);
        expect(audio.status).toBe(200);
        expect(audio.headers.get("content-type")).toBe("audio/ogg");
    }, 30_000);
});



// ─── The near track's level ──────────────────────────────────────────────────
//
// The near end is a microphone in a room, so it needs the same levelling
// dictation applies to one. Two bugs met here, and both were silent.
//
// The meeting's near capture was created with no gain at all: the configured
// value and the auto-gain loop both lived on the dictation capture. And the
// configured value never landed anywhere, because it was set before the stream
// connected, where PipeWire has no volume control yet and answers -EIO. The
// return code was discarded, so nothing said so. Auto-gain hid it on the
// dictation path by setting the gain again later, once audio was flowing.
//
// Measured against a microphone of the test's own rather than the desktop's,
// because a test cannot depend on a room. Same pw-loopback bridge the echo
// cancellation tests use.

describe.skipIf(!isLinux || !SLOW)("virtual sink: near level", () => {
    let sessionsDir = "";
    let outputModule = "";
    let loopback: ReturnType<typeof spawn> | null = null;
    let tone = "";
    let farTone = "";

    const SINK_NAME = "test_capsper_level_sink";
    const MIC_SINK = "test-capsper-level-mic-sink";
    const MIC_SOURCE = "test-capsper-level-mic-source";
    const OUT = "test_capsper_out_level";
    const LEVEL_HTTP_PORT = 43920;

    // Four times, which is +12 dB. Far enough above unity to be unmistakable,
    // and far enough below the 10x ceiling that this measures the gain rather
    // than the clamp.
    const GAIN = 4;
    const TONE_DB = -40;
    const TONE_HZ = 660;

    beforeAll(async () => {
        ensureBinary();
        outputModule = await createNullSink(OUT);

        sessionsDir = tmpFile("capsper-level-sessions", "");
        mkdirSync(sessionsDir, { recursive: true });

        // A microphone capsper can be pointed at. 16 kHz so the graph does not
        // resample twice, which would put the measurement at the mercy of a
        // converter rather than of the gain.
        loopback = spawn([
            "pw-loopback",
            `--capture-props={"media.class":"Audio/Sink", "node.name":"${MIC_SINK}", "audio.rate":16000}`,
            `--playback-props={"media.class":"Audio/Source", "node.name":"${MIC_SOURCE}", "audio.rate":16000}`,
            "-C", "1", "-m", "MONO",
        ], { stdout: "ignore", stderr: "ignore" });
        trackProc(loopback);
        await until(`${MIC_SOURCE} to appear in the graph`, async () => {
            const { exitCode } = await $`pw-link -o 2>/dev/null | grep -q ${MIC_SOURCE}`.quiet().nothrow();
            return exitCode === 0;
        });

        tone = tmpFile("capsper-level-tone", ".wav");
        await $`ffmpeg -y -f lavfi -i ${`sine=frequency=${TONE_HZ}:duration=6:sample_rate=16000`} -af ${`volume=${TONE_DB}dB`} -ac 1 ${tone}`
            .quiet()
            .nothrow();

        // Played into the meeting sink, which is what opens a session at all.
        // A different frequency so it could never be mistaken for the near
        // tone if the two tracks were ever crossed.
        farTone = tmpFile("capsper-level-far", ".wav");
        await $`ffmpeg -y -f lavfi -i ${"sine=frequency=220:duration=6:sample_rate=48000"} -af volume=-20dB -ac 2 ${farTone}`
            .quiet()
            .nothrow();
    }, 240_000);

    afterAll(async () => {
        for (const path of [tone, farTone]) {
            if (path) try { unlinkSync(path); } catch {}
        }
        try { loopback?.kill(); } catch {}
        await removeNullSink(outputModule);
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    /**
     * Record the tone through a capsper configured at `gain`, and return the
     * peak level of the near channel in the tone's band.
     *
     * A whole capsper per measurement, because the gain is a setting read at
     * startup. That is what makes the assertion self-calibrating: the band
     * filter and the graph's conversions cost the same on both runs, so
     * comparing two of these leaves only the gain.
     */
    async function nearPeakAt(gain: number): Promise<number> {
        const dir = join(sessionsDir, `g${gain}`);
        mkdirSync(dir, { recursive: true });

        const capsper = await startCapsper({
            sink: SINK_NAME,
            output: OUT,
            sessionsDir: dir,
            httpPort: LEVEL_HTTP_PORT,
            idleCloseSeconds: 3,
            audioFormat: "wav",
            near: MIC_SOURCE,
            gain,
            // Off, so what lands on disk is the configured gain and nothing
            // else. With the loop running the level would be chasing a target
            // and this would be measuring convergence instead.
            autoGain: false,
            // Off, so the near capture reads `near` directly. With it on the
            // near track comes from the cancelled node, which is a different
            // measurement with its own tests.
            aec: false,
            // The virtual microphone is one channel, and with cancellation off
            // the near capture takes the configured channel rather than mono.
            // Asking a mono node for front-left routes by position and finds
            // nothing there.
            channel: "MONO",
        });

        try {
            // Both at once: the far tone holds the session open while the near
            // tone is the one being measured.
            const far = spawn(["pw-play", "--target", SINK_NAME, farTone], { stdout: "ignore", stderr: "ignore" });
            const near = spawn(["pw-cat", "-p", `--target=${MIC_SINK}`, "--rate=16000", "--channels=1", "--format=s16", tone], { stdout: "ignore", stderr: "ignore" });
            trackProc(far);
            trackProc(near);
            await far.exited;
            await near.exited;

            await waitForLog(capsper.logFile, /session closed/, capsper.proc, 40);
            const audio = walkAudio(dir, ".wav").sort().pop()!;
            return await bandPeakDb(audio, 0, TONE_HZ);
        } finally {
            await waitForExit(capsper.proc);
            for (const path of [capsper.configFile, capsper.logFile]) {
                try { unlinkSync(path); } catch {}
            }
        }
    }

    test("captures the near end at the configured gain", async () => {
        const unity = await nearPeakAt(1);
        const boosted = await nearPeakAt(GAIN);
        const lift = boosted - unity;
        console.error(`  near peak at 1x: ${unity.toFixed(1)} dBFS, at ${GAIN}x: ${boosted.toFixed(1)} dBFS`);
        console.error(`  lift: ${lift.toFixed(1)} dB (expected ${(20 * Math.log10(GAIN)).toFixed(1)})`);

        // The difference between the two runs is the gain and nothing else.
        // Before the fix this was 0: the near capture was given no gain, and
        // the one the dictation path asked for was rejected unheard.
        const expected = 20 * Math.log10(GAIN);
        expect(lift).toBeGreaterThan(expected - 3);
        expect(lift).toBeLessThan(expected + 3);
    }, 240_000);
});
