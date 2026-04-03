import { describe, test, expect, beforeAll } from "bun:test";
import { $, spawn, file } from "bun";
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "fs";
import { ensureBinary, ensureFile, wavDuration, trackProc, saveLog } from "./helpers";

const HELPERS = "test/macos-audio-helpers";
const BINARY = "./dist/macos/bin/capsper";
const MODEL_DIR = "dist/macos/models/nemotron";
const PLIST_NAME = "io.github.danielbodart.capsper.test";
const PLIST_PATH = `/tmp/${PLIST_NAME}.plist`;

const isMacOS = process.platform === "darwin";
const hasBinary = existsSync(BINARY);
const hasModel = existsSync(`${MODEL_DIR}/encoder_model.onnx`);

async function hasBlackHole(): Promise<boolean> {
    if (!isMacOS) return false;
    if (!existsSync(HELPERS)) return false;
    const { exitCode } = await $`${HELPERS} find-device BlackHole`.quiet().nothrow();
    return exitCode === 0;
}

async function findBlackHoleId(): Promise<string> {
    const { stdout } = await $`${HELPERS} find-device BlackHole`.quiet();
    return stdout.toString().trim();
}

async function setDefaultOutput(deviceId: string): Promise<void> {
    await $`${HELPERS} set-output ${deviceId}`.quiet();
}

async function getDefaultOutput(): Promise<string> {
    const { stdout } = await $`${HELPERS} get-output`.quiet();
    return stdout.toString().trim().split("\t")[0];
}

// Grant microphone TCC permission using the shared script.
// Must be called before every test run — cdhash changes on rebuild.
async function grantMicPermission(binaryPath: string): Promise<void> {
    await $`scripts/grant-tcc.sh ${binaryPath} Microphone`.quiet().nothrow();
}

// Launch capsper via launchctl LaunchAgent — this runs in the GUI session
// which has TCC microphone permission (SSH sessions don't).
function createPlist(args: string[], outFile: string, logFile: string): string {
    const cwd = process.cwd();
    const progArgs = [
        `${cwd}/${BINARY}`,
        ...args,
    ];

    const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
${progArgs.map(a => `        <string>${a}</string>`).join("\n")}
    </array>
    <key>StandardOutPath</key>
    <string>${outFile}</string>
    <key>StandardErrorPath</key>
    <string>${logFile}</string>
    <key>RunAtLoad</key>
    <true/>

</dict>
</plist>`;
    writeFileSync(PLIST_PATH, plist);
    return PLIST_PATH;
}

async function launchService(args: string[]): Promise<{ outFile: string; logFile: string; stop: () => Promise<void> }> {
    const outFile = `/tmp/capsper-test-out-${Date.now()}.txt`;
    const logFile = `/tmp/capsper-test-log-${Date.now()}.txt`;

    // Clean up any previous run
    await $`launchctl unload ${PLIST_PATH} 2>/dev/null`.quiet().nothrow();
    writeFileSync(outFile, "");
    writeFileSync(logFile, "");

    createPlist(args, outFile, logFile);
    await $`launchctl load ${PLIST_PATH}`.quiet();

    // Wait for capture to start (up to 120s for model load + warmup)
    const deadline = Date.now() + 120_000;
    let started = false;
    while (Date.now() < deadline) {
        await Bun.sleep(500);
        try {
            const log = readFileSync(logFile, "utf-8");
            if (log.includes("Capturing audio")) { started = true; break; }
            if (log.includes("error.AudioInitFailed") || log.includes("Failed to")) {
                throw new Error(`Server failed to start: ${log.slice(-500)}`);
            }
            if (log.includes("permission denied") || log.includes("Microphone permission")) {
                throw new Error(`Microphone permission denied — grant access via System Settings or dismiss pending dialogs on the Mac desktop`);
            }
        } catch (e: any) {
            if (e.message?.startsWith("Server failed") || e.message?.startsWith("Microphone")) throw e;
        }
    }
    if (!started) {
        const log = readFileSync(logFile, "utf-8");
        throw new Error(`Server did not start capturing within 120s. Last log:\n${log.slice(-500)}`);
    }

    const stop = async () => {
        await $`launchctl unload ${PLIST_PATH} 2>/dev/null`.quiet().nothrow();
        try { unlinkSync(PLIST_PATH); } catch {}
    };

    return { outFile, logFile, stop };
}

const blackhole = await hasBlackHole();

describe.skipIf(!isMacOS || !hasBinary || !hasModel || !blackhole)("ca-stream", () => {
    let originalOutput: string;

    beforeAll(async () => {
        ensureBinary();
        // Build the audio helpers if needed
        if (!existsSync(HELPERS)) {
            await $`clang -framework CoreAudio -framework CoreFoundation test/macos-audio-helpers.c -o ${HELPERS}`;
        }
        // Save current default output to restore later
        originalOutput = await getDefaultOutput();

        // Grant microphone TCC permission to capsper binary.
        // LaunchAgent runs in GUI session but still needs a TCC entry.
        // We insert capsper's cdhash-based code requirement into the user TCC database.
        const { stdout: realPath } = await $`realpath ${BINARY}`.quiet();
        await grantMicPermission(realPath.toString().trim());
    });

    test("streams wav file via BlackHole loopback", async () => {
        const wavFile = process.env.TEST_WAV ?? "test/jfk.wav";
        ensureFile(wavFile);

        const blackholeId = await findBlackHoleId();
        console.error(`BlackHole device ID: ${blackholeId}`);

        const server = await launchService([
            "--input", "local",
            "--audio-target", "BlackHole 2ch",
            "--no-auto-gain",
            "--verbose",
        ]);

        try {
            console.error("Server capturing, playing audio via BlackHole...");

            // Route audio to BlackHole
            await setDefaultOutput(blackholeId);
            await Bun.sleep(500);

            // Play WAV (afplay uses default output = BlackHole)
            const play = spawn(["afplay", wavFile], { stdout: "ignore", stderr: "ignore" });
            trackProc(play);
            await play.exited;

            console.error("Playback done, waiting for transcription...");

            // Restore default output
            await setDefaultOutput(originalOutput);

            // Wait for pipeline to flush
            await Bun.sleep(5000);

            const output = readFileSync(server.outFile, "utf-8");
            const log = readFileSync(server.logFile, "utf-8");

            console.error("");
            console.error("=== Streaming Output ===");
            console.error(output);

            const wordCount = output.split(/\s+/).filter(Boolean).length;
            console.error(`Total words emitted: ${wordCount}`);

            expect(wordCount).toBeGreaterThan(0);
        } finally {
            await setDefaultOutput(originalOutput);
            saveLog(server.logFile, "ca-stream");
            await server.stop();
        }
    }, 180_000);
});
