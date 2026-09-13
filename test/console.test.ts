// The console serves on its own account.
//
// Every other test that reaches the HTTP server turns meeting capture on
// first, because that is what it used to take. This one deliberately leaves
// it off: the console is a setting of its own now, and the way to keep it
// that way is a test that would have been impossible to write before.

import { describe, test, expect, afterAll, beforeAll } from "bun:test";
import { writeFileSync, mkdtempSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { spawn } from "bun";
import {
    BINARY, hasGpu, ensureBinary, tmpFile, trackProc,
    waitForLog, saveLog,
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
async function startConsole(): Promise<{ base: string; logFile: string; kill: () => void }> {
    const root = mkdtempSync(join(tmpdir(), "capsper-console-"));
    const configFile = tmpFile("capsper-console", ".zon");
    writeFileSync(
        configFile,
        `.{ .http = .{ .port = 0 }, .meeting = .{ .dir = "${join(root, "sessions")}" } }\n`,
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
        return { base: `http://127.0.0.1:${port}`, logFile, kill };
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

    test("serves the page with meeting capture switched off", async () => {
        const page = await fetch(`${server.base}/`);
        expect(page.ok).toBe(true);
        expect(page.headers.get("content-type")).toContain("text/html");
        expect(await page.text()).toContain("Capsper transcripts");
    });

    test("lists no transcripts rather than failing when none were ever recorded", async () => {
        // The sessions directory is made by the first meeting, so with
        // meetings off it does not exist. An empty list is the honest answer
        // and a 500 would be the wrong one.
        const res = await fetch(`${server.base}/sessions.json`);
        expect(res.ok).toBe(true);
        expect(await res.json()).toEqual([]);
    });
});
