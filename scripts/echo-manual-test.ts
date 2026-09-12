// scripts/echo-manual-test.ts — echo cancellation, measured in a real room.
//
// The automatic tests build a room out of eight hand-written taps and play it
// between virtual devices. That proves the plumbing and gives a number, but it
// is not a room: no loudspeaker distortion, no drift between a playback clock
// and a capture clock, no furniture. This is the one that uses the actual
// speakers and the actual microphone, and it is the only honest source for the
// threshold the automatic test asserts against.
//
// Deliberately not named `*.test.ts`, so `bun test` can never discover it, and
// deliberately absent from every aggregate target in `run.ts`. It plays sound
// out loud at whoever is sitting there, so it runs when a person asks it to and
// at no other time.
//
// It runs the same call three times. Twice in silence, once with cancellation
// off and once on, because a real room offers no other way to know what was
// removed: the "before" is not something you can compute, it has to be
// recorded. Then once more with the person talking over it.
//
// That third pass is the one neither automatic test can do. The synthetic
// fixture deliberately keeps the two sides apart, so it says nothing about
// double-talk -- both ends at once, which is the hardest thing an echo
// canceller does and the one that matters most, because the failure is not a
// leaked word but a swallowed one.
//
// The operator hears the call three times and talks over the third. That is the
// whole protocol, and it is deliberately something you can follow by ear:
// nobody watching a terminal can react to a prompt in the middle of an eleven
// second recording.

import { $, spawn } from "bun";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const BINARY = "./dist/linux/bin/capsper";
const FAR_WAV = "test/jfk.wav";
const REFERENCE = "test/jfk.txt";

const SINK = "capsper_manual_echo_test";
const HTTP_PORT = 43931;

/** Words only the far end says. Finding one in the near track is leakage. */
const MARKERS = ["fellow", "americans", "country"];

function normalize(text: string): string {
    return text.toLowerCase().replace(/[^a-z0-9\s']/g, " ").replace(/\s+/g, " ").trim();
}

function countMarkers(text: string): number {
    const words = normalize(text).split(/\s+/).filter(Boolean);
    return MARKERS.reduce((n, m) => n + words.filter((w) => w === m).length, 0);
}

function voiceCues(vtt: string, voice: "Near" | "Far"): string[] {
    const out: string[] = [];
    for (const line of vtt.split("\n")) {
        const m = line.match(new RegExp(`^<v ${voice}>(.*)$`));
        if (m) out.push(m[1]);
    }
    return out;
}

async function dump(): Promise<any[]> {
    const { stdout } = await $`pw-dump`.quiet().nothrow();
    try { return JSON.parse(stdout.toString()); } catch { return []; }
}

function metadata(objects: any[], key: string): string | undefined {
    for (const o of objects) {
        if (o.type !== "PipeWire:Interface:Metadata") continue;
        for (const entry of o.metadata ?? []) {
            if (entry.key === key) return entry.value?.name;
        }
    }
    return undefined;
}

async function until(what: string, cond: () => Promise<boolean> | boolean, seconds = 60): Promise<void> {
    const deadline = Date.now() + seconds * 1000;
    while (Date.now() < deadline) {
        try { if (await cond()) return; } catch {}
        await Bun.sleep(250);
    }
    throw new Error(`Timed out after ${seconds}s waiting for ${what}`);
}

/** Mean level of one channel over a window, in dBFS. */
async function meanDb(path: string, endMs: number, channel: number): Promise<number> {
    const filter = `atrim=start=0:end=${endMs / 1000},pan=mono|c0=c${channel},volumedetect`;
    const { stderr } = await $`ffmpeg -i ${path} -af ${filter} -f null -`.quiet().nothrow();
    const mean = stderr.toString().match(/mean_volume:\s*(-?[\d.]+) dB/)?.[1];
    return mean ? parseFloat(mean) : -Infinity;
}

function findUnder(root: string, ext: string): string {
    const stack = [root];
    while (stack.length) {
        const dir = stack.pop()!;
        for (const e of readdirSync(dir, { withFileTypes: true })) {
            const full = join(dir, e.name);
            if (e.isDirectory()) stack.push(full);
            else if (e.name.endsWith(ext)) return full;
        }
    }
    throw new Error(`no ${ext} written under ${root}`);
}

/** One pass of the call, through the real speakers and the real microphone. */
async function runPass(label: string, aec: boolean, sessionsDir: string, farSeconds: number) {
    const configFile = join(sessionsDir, `config-${label}.zon`);
    // `meeting.output` is deliberately unset: the whole point is that the call
    // comes out of the real speakers and back in through the real microphone.
    writeFileSync(
        configFile,
        `.{ .meeting = .{ .enabled = true, .sink_name = "${SINK}",` +
            ` .idle_close_seconds = 4, .dir = "${sessionsDir}/${label}",` +
            ` .audio_format = .wav, .aec = .{ .enabled = ${aec} },` +
            ` .http = .{ .port = ${HTTP_PORT} } } }\n`,
    );

    const logFile = join(sessionsDir, `capsper-${label}.log`);
    const proc = spawn([BINARY, "--config", configFile], { stdout: "ignore", stderr: Bun.file(logFile) });

    try {
        await waitForLine(logFile, new RegExp(`Virtual sink '${SINK}' ready`), 180);
        await until(`${SINK} in the graph`, async () =>
            (await dump()).some((o) => o.info?.props?.["node.name"] === `${SINK}.passthrough`));
        await until("the session server", async () =>
            (await fetch(`http://127.0.0.1:${HTTP_PORT}/sessions.json`)).ok);

        console.log(`  playing ${farSeconds.toFixed(1)}s of speech through the speakers...`);
        const play = spawn(
            ["pw-cat", "-p", `--target=${SINK}`, "--rate=16000", "--channels=1", "--format=s16", FAR_WAV],
            { stdout: "ignore", stderr: "ignore" },
        );
        if ((await play.exited) !== 0) throw new Error("pw-cat failed to play into the sink");

        await waitForLine(logFile, /session closed/, 60);

        const dir = join(sessionsDir, label);
        const vtt = readFileSync(findUnder(dir, ".vtt"), "utf8");
        const audio = findUnder(dir, ".wav");
        return {
            near: voiceCues(vtt, "Near").join(" "),
            far: voiceCues(vtt, "Far").join(" "),
            // Channel 0 is the near track, over the stretch the far end was
            // talking: whatever is there is the room handing the call back.
            nearLevel: await meanDb(audio, farSeconds * 1000, 0),
        };
    } finally {
        try { proc.kill(); } catch {}
        await proc.exited;
    }
}

async function waitForLine(logFile: string, pattern: RegExp, seconds: number): Promise<void> {
    await until(`${pattern} in the log`, () => {
        try { return pattern.test(readFileSync(logFile, "utf8")); } catch { return false; }
    }, seconds);
}

export async function manualEchoTest(...argv: string[]) {
    if (process.platform !== "linux") throw new Error("Linux only: the sink is a PipeWire module.");
    if (process.env.CI) throw new Error("Refusing to run under CI: this plays audio out loud.");

    const yes = argv.includes("--yes");
    const keep = argv.includes("--keep");

    const objects = await dump();
    const speakers = metadata(objects, "default.audio.sink") ?? "(unknown)";
    const mic = metadata(objects, "default.audio.source") ?? "(unknown)";
    const farSeconds = (readFileSync(FAR_WAV).length - 44) / 32000;

    console.log("\n================ capsper echo cancellation, in your room ================");
    console.log(`  speakers    ${speakers}`);
    console.log(`  microphone  ${mic}`);
    console.log(`  playing     ${FAR_WAV} (${farSeconds.toFixed(1)}s), three times`);
    console.log("\n  This plays speech OUT LOUD and records your microphone.");
    console.log("  For a meaningful result the speakers must be audible in the room");
    console.log("  and the microphone must be open, not a headset.");
    console.log("\n  You will hear the call three times.");
    console.log("    1 and 2  stay silent -- this is the echo measurement");
    console.log("    3        talk over it -- this checks it does not eat your voice\n");

    if (/usb|bluez|headset|headphone/i.test(mic)) {
        console.log("  NOTE: that microphone name looks like a headset. If it is, there");
        console.log("        is no acoustic path from the speakers and the result will\n" +
                    "        say cancellation is unnecessary rather than that it works.\n");
    }

    if (!yes) {
        if (!process.stdin.isTTY) throw new Error("Not a terminal. Re-run with --yes if you meant it.");
        process.stdout.write("  Press Enter to start, or Ctrl-C to abort: ");
        await new Promise<void>((resolve) => process.stdin.once("data", () => resolve()));
        process.stdin.pause();
    }

    const sessionsDir = mkdtempSync(join(tmpdir(), "capsper-echo-manual-"));
    try {
        console.log("\nPass 1 of 3: cancellation OFF, stay silent");
        const off = await runPass("off", false, sessionsDir, farSeconds);
        console.log("\nPass 2 of 3: cancellation ON, stay silent");
        const on = await runPass("on", true, sessionsDir, farSeconds);
        console.log("\nPass 3 of 3: cancellation ON, TALK OVER IT");
        const talk = await runPass("talk", true, sessionsDir, farSeconds);

        const removed = on.nearLevel === -Infinity ? Infinity : off.nearLevel - on.nearLevel;
        const leakOff = countMarkers(off.near);
        const leakOn = countMarkers(on.near);

        console.log("\n================================ result ================================");
        console.log("                                    without        with");
        console.log(`  echo on the near track       ${off.nearLevel.toFixed(1).padStart(9)} dBFS ${on.nearLevel.toFixed(1).padStart(9)} dBFS`);
        console.log(`  far-end words in near track  ${String(leakOff).padStart(9)}     ${String(leakOn).padStart(9)}`);
        console.log(`\n  removed: ${removed.toFixed(1)} dB`);
        console.log(`\n  near track, cancellation off: "${normalize(off.near) || "(nothing)"}"`);
        console.log(`  near track, cancellation on:  "${normalize(on.near) || "(nothing)"}"`);
        console.log(`  far track (the control):      "${normalize(on.far).slice(0, 70)}..."`);

        // Double-talk. The failure here is not a leaked word but a swallowed
        // one, so the number that matters is how much of you survived, and
        // only you can judge that -- print it and let a human read it.
        const talkWords = normalize(talk.near).split(/\s+/).filter(Boolean).length;
        const talkLeak = countMarkers(talk.near);
        console.log("\n  ---- talking over the call ----");
        console.log(`  what it heard you say: "${normalize(talk.near) || "(nothing)"}"`);
        console.log(`  your words kept: ${talkWords}     far-end words that leaked in: ${talkLeak}`);

        // Both halves have to hold. A quieter near track with the same words
        // still in it has not solved the problem the feature exists for, and
        // no words with no level drop means the room never had an echo to
        // remove, which is a test that proved nothing.
        const worked = removed >= 3 && leakOn < leakOff;
        const nothingToDo = leakOff === 0 && removed < 3;

        console.log("\n" + "=".repeat(72));
        if (nothingToDo) {
            console.log("  INCONCLUSIVE: the microphone never heard the speakers, so there");
            console.log("  was no echo to cancel. Turn the speakers up, or use an open mic.");
        } else if (worked) {
            console.log("  PASS: the room's echo is measurably quieter and the far end's");
            console.log("  words stopped reaching the near transcript.");
            console.log(`\n  Measured ${removed.toFixed(1)} dB removed, against a floor of`);
            console.log("  minEchoRemovedDb in test/echo-cancel.test.json.");
            if (talkWords === 0) {
                console.log("\n  BUT: it heard nothing at all while you talked over the call.");
                console.log("  Either you stayed quiet through the third pass, or the");
                console.log("  cancellation is eating your voice along with the echo.");
            } else if (talkLeak > 0) {
                console.log(`\n  NOTE: ${talkLeak} far-end word(s) got through while you were`);
                console.log("  talking. Double-talk is the hardest case and some leakage");
                console.log("  there is not the same failure as leakage in silence.");
            } else {
                console.log("\n  And it kept your voice while the far end was still playing,");
                console.log("  with none of the far end's words mixed into it.");
            }
        } else {
            console.log("  FAIL: cancellation did not remove the echo in this room.");
        }
        console.log("=".repeat(72) + "\n");

        if (keep) console.log(`  recordings kept: ${sessionsDir}\n`);
        if (!worked && !nothingToDo) process.exitCode = 1;
    } finally {
        if (!keep) try { rmSync(sessionsDir, { recursive: true, force: true }); } catch {}
    }
}
