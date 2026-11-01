#!/usr/bin/env -S mise exec -- bun
import { $ } from "bun";
import { existsSync } from "fs";
import { join } from "path";
import { manualEchoTest } from "./scripts/echo-manual-test";

process.env.FORCE_COLOR = "1";

const IS_MACOS = process.platform === "darwin";
// dist/ holds only what build and dist make: this platform's runnable tree
// (bin/, models/, lib/ on Linux, and the scripts), the tarball, its .sha256
// and SHA256SUMS. What they are made from is checked in elsewhere: the
// scripts in packaging/, onnxruntime in vendor/onnxruntime.
const PLATFORM = IS_MACOS ? "macos" : "linux";
const PLATFORM_DIR = `dist/${PLATFORM}`;
const PACKAGING_DIR = `packaging/${PLATFORM}`;
const BINARY = `./${PLATFORM_DIR}/bin/capsper`;
const SCRIPT_DIR = import.meta.dir;
const TARBALL = IS_MACOS ? "capsper-macos-arm64.tar.gz" : "capsper-linux-x86_64.tar.gz";
const LIB_DIR = "vendor/onnxruntime/lib"; // Linux only — macOS uses system CoreML frameworks
// Each platform's installer and update scripts, and the one both share.
const SCRIPTS = IS_MACOS
    ? ["install.sh", "capsper-update.sh"]
    : ["install.sh", "capsper-update.sh", "capsper-apply-update.sh", "capsper-rollback.sh"];

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureDeps() {
    if (IS_MACOS) {
        await ensureDepsMacOS();
    } else {
        await ensureDepsLinux();
    }
}

async function ensureDepsMacOS() {
    if (!await which("brew")) {
        console.error("ERROR: Homebrew is required on macOS. Install from https://brew.sh");
        process.exit(1);
    }

    const missing: string[] = [];
    if (!await which("shellcheck")) missing.push("shellcheck");

    if (missing.length > 0) {
        console.log(`Installing missing brew packages: ${missing.join(", ")}`);
        await $`brew install ${missing}`;
    }
}

async function ensureDepsLinux() {
    const missing: string[] = [];

    // Core build deps
    if (!await which("pkg-config")) missing.push("pkg-config");

    // PipeWire dev headers
    const { exitCode: pwCheck } = await $`pkg-config --exists libpipewire-0.3`.quiet().nothrow();
    if (pwCheck !== 0) missing.push("libpipewire-0.3-dev");

    if (missing.length === 0) return;

    // On NixOS these come from the flake's devShell, which enterDevShell()
    // below re-runs us inside -- so anything still missing here means neither
    // that nor apt is the answer.
    if (!await which("apt")) {
        console.error(`Missing packages: ${missing.join(", ")}`);
        console.error("No apt here. Enter the flake's devShell: nix develop --command ./run");
        process.exit(1);
    }

    console.log(`Installing missing packages: ${missing.join(", ")}`);
    await $`sudo apt install -y ${missing}`;
}

/** Submodules and Git LFS objects: present after a clone, but not from it. */
async function ensureCheckout() {
    // libopus is a submodule, compiled into the binary on both platforms.
    // A no-op once initialised, so it costs a stat rather than a fetch.
    await $`git -C ${SCRIPT_DIR} submodule update --init --recursive --quiet`;

    // vendor/onnxruntime/lib/libonnxruntime.so is a Git LFS object, and a clone
    // without the LFS filters leaves a ~130-byte text pointer in its place.
    // Linking against that fails with an error that mentions neither LFS nor
    // the file, so check the size rather than wait to be confused by it.
    // macOS never reads this library: it links the system CoreML framework.
    if (IS_MACOS) return;
    const ort = Bun.file(`${LIB_DIR}/libonnxruntime.so`);
    if (await ort.exists() && ort.size < 4096) {
        console.log("Fetching Git LFS objects...");
        await $`git -C ${SCRIPT_DIR} lfs install --local`;
        await $`git -C ${SCRIPT_DIR} lfs pull`;
    }
}

function ensureBinary() {
    if (!existsSync(BINARY)) {
        console.error(`Binary not found: ${BINARY}`);
        console.error("Run: ./run.ts build");
        process.exit(1);
    }
}

// ─── Version ────────────────────────────────────────────────────────────────

async function version(): Promise<string> {
    const branch = process.env.GITHUB_REF_NAME
        || (await $`git rev-parse --abbrev-ref HEAD`.quiet()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER
        || new Date().toISOString().replace(/[-:T]/g, '').split('.')[0];
    const revisions = (await $`git rev-list --count ${branch}`.quiet()).text().trim();
    return `0.${revisions}.${buildNumber}`;
}

// ─── Commands ──────────────────────────────────────────────────────────────

export async function build() {
    await ensureCheckout();
    await ensureDeps();
    const ver = await version();
    // Symlink installed models so the binary finds them at ../models/ relative
    // to bin/. Before zig build, which installs the VAD model into models/: run
    // after, it finds a real directory there and the link is never made.
    const modelsLink = `${PLATFORM_DIR}/models`;
    const modelsTarget = join(process.env.HOME!, ".local/share/capsper/models");
    if (!existsSync(modelsLink) && existsSync(modelsTarget)) {
        await $`mkdir -p ${PLATFORM_DIR}`;
        await $`ln -s ${modelsTarget} ${modelsLink}`;
    }

    console.log(`Building v${ver} (${IS_MACOS ? "coreml" : "ort"})...`);
    // -Dcpu on Linux only: the dist build targets x86_64_v3, while macOS is
    // Apple Silicon, where Zig's native default is already right.
    if (IS_MACOS) {
        await $`zig build --prefix ${PLATFORM_DIR} -Dversion=${ver} -Doptimize=ReleaseSafe`;
    } else {
        await $`zig build --prefix ${PLATFORM_DIR} -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
    }

    // The rest of the tree install.sh runs from, as the tarball lays it out:
    // the scripts beside bin/, and on Linux the onnxruntime the binary's
    // $ORIGIN/../lib RPATH finds, linked rather than copied.
    for (const script of SCRIPTS) {
        await $`cp ${PACKAGING_DIR}/${script} ${PLATFORM_DIR}/`;
    }
    await $`cp packaging/shared/install-common.sh ${PLATFORM_DIR}/`;
    if (!IS_MACOS) {
        await $`rm -rf ${PLATFORM_DIR}/lib`;
        await $`ln -s ../../${LIB_DIR} ${PLATFORM_DIR}/lib`;
    }
}

export async function clean() {
    await $`rm -rf ${PLATFORM_DIR}/bin .zig-cache`;
    console.log("Cleaned.");
}

export async function setup() {
    await build();

    // Delegate permissions, audio detection, and service setup to install script
    const installSh = join(SCRIPT_DIR, PLATFORM_DIR, "install.sh");
    if (existsSync(installSh)) {
        await $`bash ${installSh}`;
    } else {
        console.error(`Install script not found: ${installSh}`);
    }
}

/** Default target: build → lint → unit tests → short regressions + plumbing. */
export async function dev() {
    await build();
    console.log("Running lint...");
    await lint();
    console.log("Running unit + property tests...");
    await $`zig build test`;
    console.log("Running integration smoke tests...");
    if (IS_MACOS) {
        await $`bun test test/regression.test.ts test/concurrent-tcp.test.ts test/console.test.ts test/ca-stream.test.ts`;
    } else {
        await $`bun test test/regression.test.ts test/concurrent-tcp.test.ts test/console.test.ts test/pw-stream.test.ts test/pw-sink.test.ts test/echo-cancel.test.ts`;
    }
}

export async function test() {
    await ensureCheckout();
    await ensureDeps();
    await $`zig build test`;
}

export async function shortTest() {
    ensureBinary();
    await $`bun test test/regression.test.ts`;
}

export async function mediumTest() {
    ensureBinary();
    process.env.TEST_GROUP = "medium";
    await $`bun test test/regression.test.ts`;
}

export async function longTest() {
    ensureBinary();
    process.env.TEST_GROUP = "long";
    await $`bun test test/regression.test.ts`;
}

export async function slowTest() {
    ensureBinary();
    process.env.SLOW_TESTS = "1";
    await $`bun test test/`;
}

export async function dist() {
    ensureBinary();

    if (IS_MACOS) {
        await distMacOS();
    } else {
        await distLinux();
    }
}

async function distLinux() {
    // Validate that ORT libs are real ELF binaries
    const { stdout } = await $`file ${LIB_DIR}/*.so`.quiet();
    const lines = stdout.toString().trim().split("\n");
    const bad = lines.filter(l => !l.includes("ELF") && !l.includes("symbolic link"));
    if (bad.length > 0) {
        console.error(`ERROR: ${LIB_DIR}/ contains non-ELF files:`);
        bad.forEach(l => console.error(`  ${l}`));
        process.exit(1);
    }

    // Validate the binary exists and contains no AVX-512
    const bin = `${PLATFORM_DIR}/bin/capsper`;
    if (!existsSync(bin)) {
        console.error(`ERROR: ${bin} not found — did build() run?`);
        process.exit(1);
    }
    const { stdout: objdumpOut } = await $`objdump -d ${bin} | grep -c 'zmm\\|%k[0-7],'`.quiet().nothrow();
    const avx512Count = parseInt(objdumpOut.toString().trim()) || 0;
    if (avx512Count > 0) {
        console.error(`ERROR: ${bin} contains ${avx512Count} AVX-512 instructions`);
        process.exit(1);
    }

    const ver = await version();
    await Bun.write(`${PLATFORM_DIR}/VERSION`, ver);

    // One tarball: binary, scripts, and the ONNX Runtime libraries. They were
    // split into a second "deps" asset when the CUDA execution provider made
    // them 390MB and worth not re-downloading per update; CPU-only ORT is
    // 24MB, which is smaller than the binary it sits next to. The installed
    // update script already handles a tarball carrying real .so files -- that
    // is the "old-style tarball" branch in ensure_ort_libs.
    const staging = "/tmp/capsper-dist-linux";
    await $`rm -rf ${staging}`;
    await $`mkdir -p ${staging}`;
    await $`cp -a ${PLATFORM_DIR}/bin ${staging}/`;
    await $`cp -a ${LIB_DIR} ${staging}/`;
    // The voice activity model ships rather than being downloaded: it is two
    // megabytes, it never changes, and a meeting should not be the first thing
    // to discover it is missing.
    await $`mkdir -p ${staging}/models`;
    await $`cp models/silero_vad.onnx ${staging}/models/`;
    await stageScripts(staging);
    await pack(staging, ver);
}

/** The scripts, VERSION, README and LICENSE into a tarball's staging tree. */
async function stageScripts(staging: string) {
    for (const script of SCRIPTS) {
        await $`cp ${PACKAGING_DIR}/${script} ${staging}/`;
    }
    await $`cp packaging/shared/install-common.sh ${staging}/`;
    await $`cp ${PLATFORM_DIR}/VERSION ${staging}/`;
    await $`cp README.md ${staging}/`;
    // capsper has no licence file yet; the tarball carries one once it does.
    if (existsSync("LICENSE")) await $`cp LICENSE ${staging}/`;
}

/** The staging tree as dist/<tarball>, its .sha256 (read by the installed
 *  capsper-update.sh, so it stays) and dist/SHA256SUMS. */
async function pack(staging: string, ver: string) {
    await $`tar -czf dist/${TARBALL} -C ${staging} .`;
    await $`rm -rf ${staging}`;
    await sha256(TARBALL, `${TARBALL}.sha256`);
    await sums();
    console.log(`Tarball: dist/${TARBALL} (v${ver})`);
}

/** sha256sum's line for each file in dist/, by its bare name, into dist/<out>. */
async function sha256(files: string | string[], out: string) {
    const names = Array.isArray(files) ? files : [files];
    const tool = IS_MACOS ? ["shasum", "-a", "256"] : ["sha256sum"];
    await $`${tool} ${names} > ${out}`.cwd("dist");
}

/** dist/SHA256SUMS: every tarball in dist/, which is both platforms' once
 *  CI's release job has gathered them there. */
export async function sums() {
    const tarballs = [...new Bun.Glob("*.tar.gz").scanSync("dist")].sort();
    if (tarballs.length === 0) {
        console.error("sums: no tarball in dist/");
        process.exit(1);
    }
    await sha256(tarballs, "SHA256SUMS");
}

async function distMacOS() {
    const ver = await version();
    await Bun.write(`${PLATFORM_DIR}/VERSION`, ver);

    const staging = "/tmp/capsper-dist-macos";
    await $`rm -rf ${staging}`;
    await $`mkdir -p ${staging}`;
    await $`cp -r ${PLATFORM_DIR}/bin ${staging}/`;
    await stageScripts(staging);
    await pack(staging, ver);
}

/** macOS: the Mach-O binary signed with a Fulcio certificate, and the tarball
 *  made again around it. Needs CI's OIDC token. The tarballs themselves are
 *  signed with cosign by CI's release job, once, for both platforms. */
export async function sign() {
    ensureBinary();
    if (!IS_MACOS) {
        console.log("sign: nothing to do on Linux (CI's release job signs the tarball)");
        return;
    }
    console.log("Signing macOS binary with Fulcio...");
    await $`fulcio-codesign --identifier io.github.danielbodart.capsper --subject io.github.danielbodart.capsper --entitlements packaging/macos/entitlements.plist ${PLATFORM_DIR}/bin/capsper`;
    // Re-create tarball with signed binary
    await distMacOS();
}

export async function lint() {
    await $`shellcheck packaging/linux/*.sh packaging/macos/*.sh packaging/shared/*.sh scripts/*.sh`;
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}


/** Verify the Nix flake: the package builds from source, and the NixOS module
 *  actually grants the permissions it claims (checked in a real NixOS VM).
 *  Skipped where nix is unavailable, which includes the macOS CI runner. */
export async function nix() {
    if (IS_MACOS) {
        console.log("nix: skipped (macOS — the flake packages Linux only)");
        return;
    }
    if (!await which("nix")) {
        console.log("nix: skipped (nix not installed)");
        return;
    }
    // Evaluates every output and builds the checks, including the NixOS VM
    // test. Cheap: capsper is a zig build and onnxruntime comes from the cache.
    await $`nix flake check --print-build-logs`;
    await $`nix build --no-link .#capsper`;
}
const commands: Record<string, Function> = {
    dev, build, clean, setup, test, lint, dist, sums, sign, nix, version: printVersion,
    "short-test": shortTest,
    "medium-test": mediumTest,
    "long-test": longTest,
    "slow-test": slowTest,
    // Deliberately in no aggregate above: it plays sound out loud through the
    // real speakers and records the real microphone, so it runs when a person
    // asks for it by name and at no other time.
    "manual-echo-test": manualEchoTest,
};

/**
 * On NixOS the system half of the build comes from the flake's devShell,
 * because there is no apt to install it with. An interactive shell is
 * normally already inside that shell -- direnv loads it on entering the
 * directory, see .envrc -- but a script, an editor or a CI runner is not, and
 * would otherwise fail on a missing pkg-config, or link a binary that cannot
 * find libstdc++. So re-run the command inside it.
 *
 * Nothing happens anywhere else: on any other distro these come from apt, and
 * on a NixOS machine that already entered the shell pkg-config is on PATH and
 * this returns immediately.
 */
async function enterDevShell(): Promise<boolean> {
    if (IS_MACOS || process.env.CAPSPER_DEV_SHELL) return false;
    if (!existsSync("/etc/NIXOS") || await which("pkg-config")) return false;

    const { exitCode } = await $`nix develop ${SCRIPT_DIR} --command bun ${SCRIPT_DIR}/run.ts ${process.argv.slice(2)}`
        .env({ ...process.env, CAPSPER_DEV_SHELL: "1" })
        .nothrow();
    process.exit(exitCode);
}

const command = process.argv[2] || "dev";
const args = process.argv.slice(3);

await enterDevShell();

const fn = commands[command];
if (fn) {
    try {
        await fn(...args);
    } catch (e: any) {
        console.error(`Command failed: ${command}`, ...args);
        console.error(e.message || e);
        process.exit(1);
    }
} else {
    console.error(`Unknown command: ${command}`);
    console.error(`Available: ${Object.keys(commands).join(", ")}`);
    process.exit(1);
}
