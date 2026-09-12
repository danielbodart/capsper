// test/echo-cancel.test.ts — the near track with the speakers taken out of it.
//
// Two tiers, proving different things, and it is worth being clear which is
// which because one of them is much weaker than it looks.
//
// The plumbing tier checks the shape of the graph: that the cleaned microphone
// is there when it is asked for and gone when it is not, that it does not
// steal the desktop's default input, and that the sink still carries the call
// to the speakers. That last one is not padding. Two of the properties on the
// cleaned source break the sink's pass-through when set together, with no
// error anywhere -- the call simply goes silent while everything else looks
// healthy -- so it is the assertion that catches the failure nobody would
// think to look for.
//
// The cancellation tier answers "how much of the echo goes away". It builds a
// microphone that hears the far end through a room and plays a real call into
// a real echo-cancel node. What it cannot reproduce is a real loudspeaker: no
// distortion, no drift between a playback clock and a capture clock, and no
// double-talk, since the two sides here deliberately do not overlap. Those
// belong to `./run.ts manual-echo-test`, which needs a room and a person.
//
// Nothing here plays a sound at anyone, and not because it is careful: each
// block points `meeting.output` at a null sink it owns, so the call has
// nowhere to go but a bit bucket. That also keeps the sink's idle state
// independent of whether anything else on the machine is using the speakers.
//
// Nothing here touches shared state either, and that is a repair rather than a
// design. An earlier version made its fixture the desktop's default input,
// because meeting capture had no way to be told which microphone to use. A
// real capsper on the same machine falls back to the default input whenever
// its own target lookup misses, which happens on every push-to-talk press, so
// the fixture's audio went into a live dictation session and was typed into
// whatever window had focus. `meeting.near` exists so this test can name its
// own microphone instead.

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { $, spawn, file } from "bun";
import { mkdirSync, readFileSync, readdirSync, rmSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import {
    BINARY, tmpFile, trackProc, until, waitForLog, ensureBinary, ensureFile, wavDuration,
    createNullSink, removeNullSink,
    readPcm, pcmToSamples, writeWav, roomEcho, mixToPcm, silence, concatPcm,
    countWords, voiceCues, normalize,
} from "./helpers";

const isLinux = process.platform === "linux";

// One sink name per block. They run in sequence, but a module leaving the
// graph lags the process that owned it, and a second capsper claiming a name
// the first has not let go of fails in a way that looks like the feature is
// broken rather than the test. Named for this file too, so a stray node from a
// crashed run is obvious and is never mistaken for a real `capsper_transcribe`.
const SINKS = {
    graph: "test_capsper_aec_graph",
    off: "test_capsper_aec_off",
    cancel: "test_capsper_aec_cancel",
};
const MIC_SINK = "test-capsper-aec-mic-sink";
const MIC_SOURCE = "test-capsper-aec-mic-source";
// One port per block as well, because a listening socket outlives the process
// that held it for long enough that reusing the number makes the next block
// wait on the last one's ghost.
const HTTP_PORTS = { graph: 43922, off: 43923, cancel: 43924 };
// Where each block sends the call: a sink it owns that goes nowhere. See the
// note beside the same constant in `pw-sink.test.ts` for why this replaced
// muting the pass-through.
const OUTPUT_SINKS = {
    graph: "test_capsper_aec_out_graph",
    off: "test_capsper_aec_out_off",
    cancel: "test_capsper_aec_out_cancel",
};

const thresholds = JSON.parse(readFileSync("test/echo-cancel.test.json", "utf8"));

async function dump(): Promise<any[]> {
    const { stdout } = await $`pw-dump`.quiet().nothrow();
    try { return JSON.parse(stdout.toString()); } catch { return []; }
}

function nodes(objects: any[]) {
    return objects
        .filter((o) => o.type === "PipeWire:Interface:Node")
        .map((o) => ({
            id: o.id,
            name: o.info?.props?.["node.name"],
            mediaClass: o.info?.props?.["media.class"],
        }));
}

function linkTargets(objects: any[], from: number): number[] {
    return objects
        .filter((o) => o.type === "PipeWire:Interface:Link" && o.info?.["output-node-id"] === from)
        .map((o) => o.info["input-node-id"]);
}

function defaultSourceName(objects: any[]): string | undefined {
    for (const o of objects) {
        if (o.type !== "PipeWire:Interface:Metadata") continue;
        for (const entry of o.metadata ?? []) {
            if (entry.key === "default.audio.source") return entry.value?.name;
        }
    }
    return undefined;
}

/**
 * Mean level of one channel over a window, in dBFS.
 *
 * Mean rather than peak, because the question is how much of the echo is left
 * across a whole stretch, and one surviving transient would dominate a peak.
 */
async function meanDb(path: string, startMs: number, endMs: number, channel?: number): Promise<number> {
    const pan = channel === undefined ? "anull" : `pan=mono|c0=c${channel}`;
    const filter = `atrim=start=${startMs / 1000}:end=${endMs / 1000},${pan},volumedetect`;
    const { stderr } = await $`ffmpeg -i ${path} -af ${filter} -f null -`.quiet().nothrow();
    const mean = stderr.toString().match(/mean_volume:\s*(-?[\d.]+) dB/)?.[1];
    return mean ? parseFloat(mean) : -Infinity;
}

async function startCapsper(opts: {
    aec: boolean;
    sink: string;
    output: string;
    near?: string;
    httpPort: number;
    sessionsDir: string;
    idleCloseSeconds?: number;
    /** On for the tests about what a live level controller does to a call. */
    autoGain?: boolean;
}) {
    const configFile = tmpFile("capsper-aec-config", ".zon");
    // Unity gain and no levelling unless a test asks otherwise, because the
    // echo measurements compare the recording against the fixture that went
    // into the microphone. Any gain capsper applies lands on the recording and
    // not on the fixture, so it would subtract from the removal figure one for
    // one and read as a canceller that had stopped working. These tests are
    // about cancellation; levelling has its own.
    writeFileSync(
        configFile,
        `.{ .audio = .{ .gain = 1.0, .auto_gain = ${opts.autoGain ?? false} },` +
            ` .meeting = .{ .enabled = true, .sink_name = "${opts.sink}",` +
            ` .output = "${opts.output}",` +
            (opts.near ? ` .near = "${opts.near}",` : "") +
            ` .idle_close_seconds = ${opts.idleCloseSeconds ?? 3}, .dir = "${opts.sessionsDir}",` +
            ` .audio_format = .wav, .aec = .{ .enabled = ${opts.aec} },` +
            ` .http = .{ .port = ${opts.httpPort} } } }\n`,
    );

    const logFile = tmpFile("capsper-aec", ".log");
    const proc = spawn([BINARY, "--config", configFile], {
        stdout: "ignore",
        stderr: file(logFile),
    });
    trackProc(proc);

    try {
        // 180s: the model loads before the process settles, and a first CUDA
        // run compiles PTX.
        await waitForLog(logFile, new RegExp(`Virtual sink '${opts.sink}' ready`), proc, 180);
        await until(`${opts.sink} to reach the graph`, async () =>
            nodes(await dump()).some((n) => n.name === `${opts.sink}.passthrough`));
        await until(`the session server on ${opts.httpPort}`, async () =>
            (await fetch(`http://127.0.0.1:${opts.httpPort}/sessions.json`)).ok);
    } catch (e) {
        // Without this the failure is a bare timeout and capsper's own account
        // of what went wrong is deleted with the log file.
        console.error(`  capsper log:\n${readFileSync(logFile, "utf8")}`);
        // And without this it leaks. `afterAll` only knows about a capsper
        // this function returned, so one that fails on the way up is never
        // stopped -- and it keeps its sink, under the name the next run will
        // use. Two sinks with one name is not an error anywhere: the watch
        // latches onto one, the audio goes to the other, and every later run
        // fails with no session and no explanation.
        try { proc.kill(); } catch {}
        throw e;
    }

    return { proc, configFile, logFile };
}

async function stopCapsper(c: { proc: any; configFile: string; logFile: string }) {
    try { c.proc.kill(); } catch {}
    await until("capsper to exit", () => c.proc.exitCode !== null || c.proc.signalCode !== null);
    for (const p of [c.configFile, c.logFile]) {
        try { unlinkSync(p); } catch {}
    }
}

// ─── The graph ───────────────────────────────────────────────────────────────

describe.skipIf(!isLinux)("echo cancellation: the graph", () => {
    const sessionsDir = tmpFile("capsper-aec-sessions", "");
    let capsper: Awaited<ReturnType<typeof startCapsper>> | undefined;
    let objects: any[] = [];
    let outputModule = "";

    beforeAll(async () => {
        ensureBinary();
        outputModule = await createNullSink(OUTPUT_SINKS.graph);
        mkdirSync(sessionsDir, { recursive: true });
        capsper = await startCapsper({
            aec: true, sink: SINKS.graph, output: OUTPUT_SINKS.graph,
            httpPort: HTTP_PORTS.graph, sessionsDir,
        });
        objects = await dump();
    }, 180_000);

    afterAll(async () => {
        if (capsper) await stopCapsper(capsper);
        await removeNullSink(outputModule);
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    test("cancels nothing until there is a call to cancel", () => {
        // The canceller is not idle-able: it schedules the sink alongside its
        // own streams, so leaving it up would hold the graph turning over to
        // remove echo from calls that are not happening. On a laptop that is a
        // core spent on nothing. So it comes up with a session, and until then
        // the cleaned microphone does not exist at all.
        expect(nodes(objects).some((n) => n.name === `${SINKS.graph}.mic`)).toBe(false);
    });

    test("is not running while nothing is playing into it", () => {
        // The property that pays for the above: cancellation must not hold the
        // graph turning over between calls.
        //
        // `running` rather than `suspended`, for the reason spelled out beside
        // the same assertion in `pw-sink.test.ts`. The sink cannot reach
        // `suspended` while anything else on the machine is using the
        // speakers, because its pass-through is linked to them.
        const sink = objects.find((o) =>
            o.type === "PipeWire:Interface:Node" && o.info?.props?.["node.name"] === SINKS.graph);
        expect(sink?.info?.state).not.toBe("running");
    });

    test("still carries the call to the speakers", () => {
        // The regression this file exists for. `media.class` of
        // Audio/Source/Virtual and `audio.position = [ MONO ]` on the cleaned
        // source are each harmless alone and together stop the sink's
        // pass-through linking to the default output -- silently, and in a
        // place that looks unrelated to either property.
        const passthrough = nodes(objects).find((n) => n.name === `${SINKS.graph}.passthrough`);
        expect(passthrough).toBeDefined();
        expect(linkTargets(objects, passthrough!.id).length).toBeGreaterThan(0);
    });

    test("opens no session while nothing is playing into the sink", async () => {
        // Gate 1 still has to distinguish a call from an idle machine, or
        // every session becomes one long meeting.
        //
        // Asserted on behaviour rather than on the sink's state, and the
        // difference is not pedantry. With cancellation on, the sink node sits
        // in `running` permanently, because it is one of the four streams the
        // canceller schedules together. An earlier version of this test read
        // that state and called it a regression. It is not: gate 1 counts the
        // application streams *linked* to the sink, which is a different
        // question from whether the sink itself is turning over.
        await Bun.sleep(5000);
        expect(readdirSync(sessionsDir)).toHaveLength(0);
    }, 15_000);
});

describe.skipIf(!isLinux)("echo cancellation: turned off", () => {
    const sessionsDir = tmpFile("capsper-aec-off-sessions", "");
    let capsper: Awaited<ReturnType<typeof startCapsper>> | undefined;
    let outputModule = "";

    beforeAll(async () => {
        ensureBinary();
        outputModule = await createNullSink(OUTPUT_SINKS.off);
        mkdirSync(sessionsDir, { recursive: true });
        capsper = await startCapsper({
            aec: false, sink: SINKS.off, output: OUTPUT_SINKS.off,
            httpPort: HTTP_PORTS.off, sessionsDir,
        });
    }, 180_000);

    afterAll(async () => {
        if (capsper) await stopCapsper(capsper);
        await removeNullSink(outputModule);
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    test("makes no cleaned microphone at all", async () => {
        expect(nodes(await dump()).some((n) => n.name === `${SINKS.off}.mic`)).toBe(false);
    });

    test("still carries the call to the speakers", async () => {
        const objects = await dump();
        const passthrough = nodes(objects).find((n) => n.name === `${SINKS.off}.passthrough`);
        expect(passthrough).toBeDefined();
        expect(linkTargets(objects, passthrough!.id).length).toBeGreaterThan(0);
    });
});

// ─── Cancellation ────────────────────────────────────────────────────────────

const FAR_WAV = "test/jfk.wav";
const NEAR_WAV = "test/working-test.wav";

/** Quiet between the far end finishing and the near end starting. */
const GAP_MS = 1500;

/** How far ahead of the microphone the far end starts. See the spawn below. */
const HEAD_START_MS = 300;

/**
 * A microphone that hears the room: the near end talking, and the far end
 * arriving back off the speakers a few milliseconds later.
 *
 * The two do not overlap. That is a simplification and worth naming as one --
 * real calls interrupt each other, and an echo canceller's hardest moment is
 * when both ends talk at once. What non-overlap buys is an unambiguous
 * question: the far end's words have no business in the near end's transcript
 * at any point, so counting them needs no judgement about who said what.
 */
function buildFixtures(micPath: string, farPath: string, echoGain: number): void {
    const far = pcmToSamples(readPcm(FAR_WAV));
    const near = pcmToSamples(readPcm(NEAR_WAV));

    const farMs = (far.length / 16000) * 1000;
    const echo = roomEcho(far, echoGain);
    const nearSide = concatPcm(silence(farMs + GAP_MS), near);
    const mic = mixToPcm(echo, nearSide);
    writeWav(micPath, mic);

    // The far side is padded with silence to the length of the whole fixture,
    // and that is load-bearing rather than tidy. The cleaned microphone is one
    // of four streams the canceller schedules together, so it produces nothing
    // at all while the sink has no input -- stop playing into the sink and the
    // near track records digital silence, which reads exactly like
    // cancellation that works far too well. A real call holds its output open
    // and streams silence between sentences, so padding is also the honest
    // imitation of one.
    writeWav(farPath, concatPcm(far, silence((mic.length / 16000) * 1000 - farMs)));
}

describe.skipIf(!isLinux)("echo cancellation: a far end coming back off the speakers", () => {
    const sessionsDir = tmpFile("capsper-aec-cancel-sessions", "");
    const micWav = tmpFile("capsper-aec-mic", ".wav");
    const farWav = tmpFile("capsper-aec-far", ".wav");
    let capsper: Awaited<ReturnType<typeof startCapsper>> | undefined;
    let loopback: ReturnType<typeof spawn> | undefined;
    let nearText = "";
    let farText = "";
    let removedDb = 0;
    let duringCall: any[] = [];
    let outputModule = "";

    const markers: string[] = thresholds.markerWords;

    beforeAll(async () => {
        ensureBinary();
        ensureFile(FAR_WAV);
        ensureFile(NEAR_WAV);
        outputModule = await createNullSink(OUTPUT_SINKS.cancel);
        mkdirSync(sessionsDir, { recursive: true });

        buildFixtures(micWav, farWav, thresholds.echoGain);

        // A microphone capsper can be pointed at. Same bridge the streaming
        // regressions use, at 16 kHz so the graph does not resample twice.
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

        capsper = await startCapsper({
            aec: true,
            sink: SINKS.cancel,
            output: OUTPUT_SINKS.cancel,
            near: MIC_SOURCE,
            httpPort: HTTP_PORTS.cancel,
            sessionsDir,
            // Long enough to outlast the far end finishing and the near end
            // still talking: the idle countdown starts when the sink goes
            // quiet, not when the microphone does.
            idleCloseSeconds: 20,
        });

        // The far end goes into capsper's sink, which is what the canceller
        // subtracts, and the room goes into the microphone.
        //
        // The sink starts first, and the head start matters. An echo canceller
        // can only remove a sound it has already heard on its reference, and
        // two processes started in the same breath come up in either order
        // with a spread of tens of milliseconds. Start the microphone first
        // and the echo arrives before the thing that caused it, which is not
        // an echo any more and cannot be cancelled by anything.
        const intoSink = spawn(
            ["pw-cat", "-p", `--target=${SINKS.cancel}`, "--rate=16000", "--channels=1", "--format=s16", farWav],
            { stdout: "ignore", stderr: "pipe" },
        );
        trackProc(intoSink);
        await Bun.sleep(HEAD_START_MS);
        const intoMic = spawn(
            ["pw-cat", "-p", `--target=${MIC_SINK}`, "--rate=16000", "--channels=1", "--format=s16", micWav],
            { stdout: "ignore", stderr: "pipe" },
        );
        trackProc(intoMic);

        // Captured mid-call, because the cleaned microphone only exists while
        // a session is open.
        await Bun.sleep(2000);
        duringCall = await dump();

        const [sinkCode, micCode] = await Promise.all([intoSink.exited, intoMic.exited]);
        if (sinkCode !== 0 || micCode !== 0) {
            // Ignoring these would turn "the audio never played" into "the
            // canceller removed everything", which is the wrong conclusion to
            // draw from a green test.
            const errs = await Promise.all([
                new Response(intoSink.stderr).text(),
                new Response(intoMic.stderr).text(),
            ]);
            throw new Error(`pw-cat failed (sink ${sinkCode}, mic ${micCode}):\n${errs.join("\n")}`);
        }

        await waitForLog(capsper.logFile, /session closed/, capsper.proc, 60);

        // Levels before text, because the transcript cannot tell three
        // failures apart: nothing cancelled, everything cancelled, and a
        // microphone that never arrived all read wrong in the same way. How
        // much quieter the echo got is the number that says which, and it is
        // the number worth tuning against.
        const audio = findSessionPath(sessionsDir, ".wav");
        const farMs = Number(wavDuration(FAR_WAV)) * 1000;
        const before = await meanDb(micWav, 0, farMs);
        const after = await meanDb(audio, 0, farMs, 0);
        removedDb = before - after;
        console.error(`  echo into the microphone:    ${before.toFixed(1)} dBFS`);
        console.error(`  echo left on the near track: ${after.toFixed(1)} dBFS`);
        console.error(`  removed:                     ${removedDb.toFixed(1)} dB`);

        const vtt = readFileSync(findSessionPath(sessionsDir, ".vtt"), "utf8");
        nearText = voiceCues(vtt, "Near").join(" ");
        farText = voiceCues(vtt, "Far").join(" ");
        console.error(`  near: "${normalize(nearText)}"`);
        console.error(`  far:  "${normalize(farText)}"`);
    }, 180_000);

    afterAll(async () => {
        if (capsper) await stopCapsper(capsper);
        await removeNullSink(outputModule);
        try { loopback?.kill(); } catch {}
        for (const p of [micWav, farWav]) { try { unlinkSync(p); } catch {} }
        try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    });

    test("exposes a cleaned microphone named after the sink", () => {
        // Named from the sink rather than configured separately, so renaming
        // the sink cannot leave a node behind under the shipped name.
        const mic = nodes(duringCall).find((n) => n.name === `${SINKS.cancel}.mic`);
        expect(mic).toBeDefined();
        // A plain Audio/Source, deliberately. Audio/Source/Virtual reads as
        // "not a real microphone" to the session manager, which hides it from
        // the desktop and from capsper's own near capture alike: the stream
        // finds nothing to link to and the near track records digital silence.
        expect(mic!.mediaClass).toBe("Audio/Source");
    });

    test("does not take over the desktop's default input", () => {
        // A source appearing on its own and becoming everyone's microphone
        // would send call audio into every other application on the machine.
        // `priority.session = 0` is the only thing preventing it, now that the
        // Virtual class has turned out to cost too much.
        expect(defaultSourceName(duringCall)).not.toBe(`${SINKS.cancel}.mic`);
    });

    test("still hears the far end on the far track", () => {
        // The control. Cancelling the near track must not touch the far one,
        // and a transcript empty everywhere would pass the other assertions
        // for entirely the wrong reason.
        const found = countWords(farText, markers);
        const total = Object.values(found).reduce((a, b) => a + b, 0);
        expect(total).toBeGreaterThanOrEqual(thresholds.minFarMarkersOnFarTrack);
    });

    test("still hears the near end", () => {
        // The other way a canceller can pass: by muting everything. Coverage
        // of what the near end actually said is what rules that out.
        const said = normalize(readFileSync("test/working-test.txt", "utf8")).split(/\s+/).filter(Boolean);
        const heard = new Set(normalize(nearText).split(/\s+/).filter(Boolean));
        const hits = said.filter((w) => heard.has(w)).length;
        const coverage = Math.round((hits / said.length) * 100);
        console.error(`  near-end coverage: ${coverage}%`);
        expect(coverage).toBeGreaterThanOrEqual(thresholds.minNearCoverage);
    });

    test("makes the echo measurably quieter on the near track", () => {
        // A level, not a transcript, and the two are worth keeping apart. This
        // one is what the canceller directly controls, so it is the assertion
        // that moves when the canceller stops working. It caught the failure
        // that mattered: with a channel position forced on the canceller's
        // microphone, WebRTC rejected every frame and this read zero while
        // everything else about the graph looked correct.
        expect(removedDb).toBeGreaterThanOrEqual(thresholds.minEchoRemovedDb);
    });

    test("keeps the far end out of the near track", () => {
        // And this one is what it is all for. Words only the far end said must
        // not be attributed to the near end, however loudly the speakers
        // played them.
        const found = countWords(nearText, markers);
        const total = Object.values(found).reduce((a, b) => a + b, 0);
        console.error(`  far words in the near track: ${JSON.stringify(found)}`);
        expect(total).toBeLessThanOrEqual(thresholds.maxFarMarkersOnNearTrack);
    });
});

/** One file a session wrote, wherever the dated path put it. */
function findSessionPath(root: string, ext: string): string {
    const stack = [root];
    while (stack.length) {
        const dir = stack.pop()!;
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
            const full = join(dir, entry.name);
            if (entry.isDirectory()) stack.push(full);
            else if (entry.name.endsWith(ext)) return full;
        }
    }
    throw new Error(`no ${ext} written under ${root}`);
}
