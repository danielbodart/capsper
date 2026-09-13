// The console serves on its own account.
//
// Every other test that reaches the HTTP server turns meeting capture on
// first, because that is what it used to take. This one deliberately leaves
// it off: the console is a setting of its own now, and the way to keep it
// that way is a test that would have been impossible to write before.

import { describe, test, expect, afterAll, beforeAll } from "bun:test";
import { writeFileSync, readFileSync, mkdtempSync, mkdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { spawn } from "bun";
import {
    BINARY, hasGpu, ensureBinary, tmpFile, trackProc,
    waitForLog, saveLog, writeWav, silence, until,
} from "./helpers";

const gpu = await hasGpu();

const extraArgs: string[] = [
    ...(process.env.ASR_MODEL ? ["--model", process.env.ASR_MODEL] : []),
];

/// Start capsper with the console on, meeting capture off, and a TCP port so
/// there is something for it to be running alongside. Port zero throughout,
/// so nothing here collides with a capsper the developer has running.
///
/// The sessions directory is named and pointed at an empty temporary tree.
/// Left at its default it is the developer's own `~/.local/share/capsper`,
/// and a test that reads whatever real meetings happen to be on the machine
/// passes or fails by what its author did last week.
async function startConsole(): Promise<{ base: string; recordingsDir: string; configFile: string; proc: ReturnType<typeof spawn>; logFile: string; kill: () => void }> {
    const root = mkdtempSync(join(tmpdir(), "capsper-console-"));

    // Debug recordings written before capsper starts, deliberately out of
    // numeric order: the ring numbers files `seq % keep`, so after it wraps
    // the newest has the lowest number. `009` is written first and must
    // therefore come last.
    const recordingsDir = join(root, "recordings");
    mkdirSync(recordingsDir);
    for (const id of ["009", "000", "004"]) {
        writeWav(join(recordingsDir, `${id}.wav`), silence(500));
        writeFileSync(
            join(recordingsDir, `${id}.vtt`),
            `WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\n<v Near>recording ${id}\n`,
        );
        // A whole second apart, so the ordering cannot turn on timestamp
        // resolution.
        await Bun.sleep(1100);
    }

    const configFile = tmpFile("capsper-console", ".zon");
    writeFileSync(
        configFile,
        `.{ .http = .{ .port = 0 },` +
            ` .meeting = .{ .dir = "${join(root, "sessions")}" },` +
            ` .debug_recording = .{ .dir = "${recordingsDir}" } }\n`,
    );

    const logFile = tmpFile("capsper-console", ".log");
    const proc = spawn([BINARY, "--config", configFile, "--port", "0", ...extraArgs], {
        stdout: Bun.file(logFile),
        stderr: Bun.file(logFile),
    });
    trackProc(proc);

    const kill = () => {
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        // The same 180s the TCP helper allows: a first CUDA run compiles PTX
        // during warmup and the console is up long before that finishes, but
        // the log line it is waited for arrives on the same startup path.
        const line = await waitForLog(logFile, /Console at http:\/\/[\d.]+:(\d+)/, proc, 180);
        const port = parseInt(line.match(/:(\d+)/)![1]);
        return { base: `http://127.0.0.1:${port}`, recordingsDir, configFile, proc, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

describe.skipIf(!gpu)("console", () => {
    let server: Awaited<ReturnType<typeof startConsole>>;

    beforeAll(async () => {
        ensureBinary();
        server = await startConsole();
    });

    afterAll(() => {
        if (server) {
            saveLog(server.logFile, "console");
            server.kill();
        }
    });

    test("serves the transcripts page with meeting capture switched off", async () => {
        const page = await fetch(`${server.base}/transcripts`);
        expect(page.ok).toBe(true);
        expect(page.headers.get("content-type")).toContain("text/html");
        expect(await page.text()).toContain("Capsper transcripts");
    });

    test("says what the running service is, at the root", async () => {
        const page = await fetch(`${server.base}/`);
        expect(page.ok).toBe(true);
        const html = await page.text();

        // What it is: this binary, and the model it was pointed at.
        expect(html).toContain("Backend");
        expect(html).toContain("nemotron");
        // What it is doing: a TCP port is open and nobody is on it, meeting
        // capture is off, and nothing is being dictated.
        expect(html).toContain("Remote clients");
        expect(html).toMatch(/Meeting<\/dt><dd[^>]*>off/);
        expect(html).toContain("not held");
    });

    test("shares one stylesheet between the pages", async () => {
        const css = await fetch(`${server.base}/style.css`);
        expect(css.ok).toBe(true);
        expect(css.headers.get("content-type")).toContain("text/css");
        expect(await css.text()).toContain("--accent");
    });

    test("lists no transcripts rather than failing when none were ever recorded", async () => {
        // The sessions directory is made by the first meeting, so with
        // meetings off it does not exist. An empty list is the honest answer
        // and a 500 would be the wrong one.
        const res = await fetch(`${server.base}/sessions.json`);
        expect(res.ok).toBe(true);
        expect(await res.json()).toEqual([]);
    });

    test("lists debug recordings newest first, by when they were written", async () => {
        // The whole point of ordering these by modification time: the ring
        // numbers files `seq % keep`, so `000` is newer than `009` here and
        // sorting by name would put it in the wrong place entirely.
        const body = await (await fetch(`${server.base}/recordings.json`)).json();
        expect(body.enabled).toBe(true);
        expect(body.items.map((r: { id: string }) => r.id)).toEqual(["004", "000", "009"]);
        // The transcript beside each one is not listed as a thing to play.
        expect(body.items.every((r: { audio: string }) => r.audio.endsWith(".wav"))).toBe(true);
    });

    test("serves a debug recording's audio and transcript", async () => {
        const wav = await fetch(`${server.base}/d/004.wav`);
        expect(wav.ok).toBe(true);
        expect(wav.headers.get("content-type")).toBe("audio/wav");

        const vtt = await fetch(`${server.base}/d/004.vtt`);
        expect(vtt.ok).toBe(true);
        expect(vtt.headers.get("content-type")).toBe("text/vtt");
        expect(await vtt.text()).toContain("recording 004");
    });

    test("will not be walked out of the recordings directory", async () => {
        // The same guard the sessions route has, on a route that reaches a
        // different tree. Neither prefix may be used to read the other's
        // files, or anything else on the machine.
        for (const path of ["/d/../../../../etc/passwd", "/d/../sessions"]) {
            const res = await fetch(`${server.base}${path}`);
            expect(res.status).toBeGreaterThanOrEqual(400);
        }
    });

    test("serves the recordings page at its own address", async () => {
        const page = await fetch(`${server.base}/recordings/004`);
        expect(page.ok).toBe(true);
        expect(page.headers.get("content-type")).toContain("text/html");
    });

    test("offers every setting, with the prose from config.zig beside it", async () => {
        const html = await (await fetch(`${server.base}/settings`)).text();

        // A control per shape, named by the dotted path the config file uses.
        expect(html).toContain('name="audio.gain"');
        expect(html).toContain('name="meeting.enabled"');
        expect(html).toContain('<select id="audio.channel"');
        // Enum choices come from the type, so every channel is offered.
        expect(html).toContain('<option value="AUX63"');
        // The doc comment beside the field reaches the page.
        expect(html).toContain("Capture device node name");
        // It shows what is running, not the compiled defaults: this capsper
        // was started with a debug directory and an OS-assigned HTTP port.
        expect(html).toContain(server.recordingsDir);
    });

    test("refuses a value that is not of its field's type, and writes nothing", async () => {
        const before = readFileSync(server.configFile, "utf8");

        const res = await fetch(`${server.base}/settings`, {
            method: "POST",
            body: new URLSearchParams({ "audio.channel": "SIDEWAYS" }),
        });
        const html = await res.text();
        expect(html).toContain("Nothing was saved");
        expect(html).toContain("audio.channel");

        expect(readFileSync(server.configFile, "utf8")).toBe(before);
        // And it is still running: a refused save is not a restart.
        expect(server.proc.exitCode).toBeNull();
    });

    // Last, because it ends the process. Everything above needs it alive.
    test("saves only what differs from the defaults, then leaves to be restarted", async () => {
        const res = await fetch(`${server.base}/settings`, {
            method: "POST",
            body: new URLSearchParams({
                "audio.gain": "2.5",
                // Equal to the compiled default, and posted the way a browser
                // posts every field whether or not it was touched. It must not
                // reach the file: a file naming every default freezes today's
                // into it.
                "http.bind": "127.0.0.1",
                "meeting.sink_name": "capsper_transcribe",
                // A tilde the person typed stays a tilde. The running settings
                // have this expanded to an absolute path, and saving that
                // would bake one machine's home directory into the file. A
                // path that is not the field's default, so it must appear.
                "meeting.dir": "~/capsper-meetings",
            }),
        });
        expect(await res.text()).toContain("Saved to");

        const saved = readFileSync(server.configFile, "utf8");
        expect(saved).toContain(".gain = 2.5");
        expect(saved).toContain(`.dir = "~/capsper-meetings"`);
        expect(saved).not.toContain(".bind");
        expect(saved).not.toContain(".sink_name");
        // Each setting carries its description, as `--write-config` writes it.
        expect(saved).toContain("// Multiplier applied to the incoming samples");

        await until("capsper to leave so the service manager can restart it", () =>
            server.proc.exitCode !== null || server.proc.signalCode !== null);
    });
});
