#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";
import { join } from "path";
import { manualEchoTest } from "./scripts/echo-manual-test";

process.env.FORCE_COLOR = "1";

const IS_MACOS = process.platform === "darwin";
const PLATFORM_DIR = IS_MACOS ? "dist/macos" : "dist/linux";
const BINARY = IS_MACOS ? `./${PLATFORM_DIR}/bin/capsper` : `./${PLATFORM_DIR}/bin/capsper-cuda`;
const SCRIPT_DIR = import.meta.dir;
const TARBALL = IS_MACOS ? "capsper-macos-arm64.tar.gz" : "capsper-linux-x86_64.tar.gz";
const DEPS_TARBALL = "capsper-linux-x86_64-deps.tar.gz";
const LIB_DIR = "dist/linux/lib"; // Linux only — macOS uses system CoreML frameworks

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

    // On NixOS these arrive from the flake's devShell, which bootstrap.sh
    // enters before we get here -- so anything still missing means that did
    // not happen, and apt is not the answer.
    if (!await which("apt")) {
        console.error(`Missing packages: ${missing.join(", ")}`);
        console.error("No apt here. On NixOS run through the flake: nix develop --command ./run");
        process.exit(1);
    }

    console.log(`Installing missing packages: ${missing.join(", ")}`);
    await $`sudo apt install -y ${missing}`;
}

function ensureBinary() {
    if (IS_MACOS) {
        if (!existsSync(`./${PLATFORM_DIR}/bin/capsper`)) {
            console.error(`Binary not found: ./${PLATFORM_DIR}/bin/capsper`);
            console.error("Run: ./run.ts build");
            process.exit(1);
        }
    } else {
        if (!existsSync(`./${PLATFORM_DIR}/bin/capsper-cuda`) && !existsSync(`./${PLATFORM_DIR}/bin/capsper-cpu`)) {
            console.error(`No binaries found in ${PLATFORM_DIR}/bin/`);
            console.error("Run: ./run.ts build");
            process.exit(1);
        }
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
    await ensureDeps();
    const ver = await version();
    if (IS_MACOS) {
        console.log(`Building v${ver} (coreml)...`);
        await $`zig build --prefix ${PLATFORM_DIR} -Dversion=${ver} -Doptimize=ReleaseSafe`;
        // Symlink installed models so the binary finds them at ../models/ relative to bin/
        const modelsLink = `${PLATFORM_DIR}/models`;
        const modelsTarget = join(process.env.HOME!, ".local/share/capsper/models");
        if (!existsSync(modelsLink) && existsSync(modelsTarget)) {
            await $`ln -s ${modelsTarget} ${modelsLink}`;
        }
    } else {
        console.log(`Building v${ver} (ort-cuda)...`);
        await $`zig build --prefix ${PLATFORM_DIR} -Dbackend=ort_cuda -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
        console.log(`Building v${ver} (ort-cpu)...`);
        await $`zig build --prefix ${PLATFORM_DIR} -Dbackend=ort_cpu -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
        // Symlink capsper → capsper-cuda for dev (dist creates a proper launcher script)
        await $`ln -sf capsper-cuda ${PLATFORM_DIR}/bin/capsper`;
        // Symlink installed models so the binary finds them at ../models/ relative to bin/
        const modelsLink = `${PLATFORM_DIR}/models`;
        const modelsTarget = join(process.env.HOME!, ".local/share/capsper/models");
        if (!existsSync(modelsLink) && existsSync(modelsTarget)) {
            await $`ln -s ${modelsTarget} ${modelsLink}`;
        }
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
    await $`shellcheck dist/linux/*.sh dist/macos/*.sh dist/shared/*.sh scripts/*.sh bootstrap.sh`;
    console.log("Running unit + property tests...");
    await $`zig build test`;
    console.log("Running integration smoke tests...");
    if (IS_MACOS) {
        await $`bun test test/regression.test.ts test/concurrent-tcp.test.ts test/ca-stream.test.ts`;
    } else {
        await $`bun test test/regression.test.ts test/concurrent-tcp.test.ts test/pw-stream.test.ts test/pw-sink.test.ts test/echo-cancel.test.ts`;
    }
}

export async function test() {
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
        console.error("ERROR: dist/linux/lib/ contains non-ELF files:");
        bad.forEach(l => console.error(`  ${l}`));
        process.exit(1);
    }

    // Validate both binaries exist and contain no AVX-512
    for (const bin of [`${PLATFORM_DIR}/bin/capsper-cuda`, `${PLATFORM_DIR}/bin/capsper-cpu`]) {
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
    }

    // Replace dev symlink with a default capsper → capsper-cpu for the tarball.
    // The installer/apply-update overrides this with the correct variant (cuda or cpu)
    // based on GPU detection. The default ensures compatibility with older update
    // scripts that validate bin/capsper exists.
    await $`ln -sf capsper-cpu ${PLATFORM_DIR}/bin/capsper`;

    const ver = await version();
    await Bun.write(`${PLATFORM_DIR}/VERSION`, ver);

    // Generate DEPS_VERSION from sha256 of real ORT libs (skip symlinks)
    const { stdout: depsHash } = await $`find ${LIB_DIR} -name '*.so' -not -type l | sort | xargs sha256sum | sha256sum | cut -d' ' -f1`.quiet();
    const depsVersion = depsHash.toString().trim();

    // Binary tarball: binaries + scripts + lib/DEPS_VERSION marker
    // lib/ dir with just DEPS_VERSION satisfies old update scripts that check [ -d lib ]
    const staging = "/tmp/capsper-dist-linux";
    await $`rm -rf ${staging}`;
    await $`mkdir -p ${staging}`;
    await $`cp -a ${PLATFORM_DIR}/bin ${staging}/`;
    // The voice activity model ships rather than being downloaded: it is two
    // megabytes, it never changes, and a meeting should not be the first thing
    // to discover it is missing.
    await $`mkdir -p ${staging}/models`;
    await $`cp models/silero_vad.onnx ${staging}/models/`;
    await $`mkdir -p ${staging}/lib`;
    await Bun.write(`${staging}/lib/DEPS_VERSION`, depsVersion);
    for (const script of ["install.sh", "capsper-update.sh", "capsper-apply-update.sh", "capsper-rollback.sh"]) {
        await $`cp ${PLATFORM_DIR}/${script} ${staging}/`;
    }
    await $`cp dist/shared/install-common.sh ${staging}/`;
    await $`cp ${PLATFORM_DIR}/VERSION ${staging}/`;
    await $`tar -czf ${TARBALL} -C ${staging} .`;
    await $`sha256sum ${TARBALL} > ${TARBALL}.sha256`;
    await $`rm -rf ${staging}`;
    console.log(`Tarball: ${TARBALL} (v${ver})`);

    // Deps tarball: ORT shared libs + DEPS_VERSION
    const depsStaging = "/tmp/capsper-dist-deps";
    await $`mkdir -p ${depsStaging}/lib`;
    await $`cp -a ${LIB_DIR}/libonnxruntime* ${depsStaging}/lib/`;
    await Bun.write(`${depsStaging}/lib/DEPS_VERSION`, depsVersion);
    await $`tar -czf ${DEPS_TARBALL} -C ${depsStaging} .`;
    await $`sha256sum ${DEPS_TARBALL} > ${DEPS_TARBALL}.sha256`;
    await $`rm -rf ${depsStaging}`;
    console.log(`Deps tarball: ${DEPS_TARBALL} (${depsVersion.slice(0, 12)})`);
}

async function distMacOS() {
    const ver = await version();
    await Bun.write(`${PLATFORM_DIR}/VERSION`, ver);

    const staging = "/tmp/capsper-dist-macos";
    await $`rm -rf ${staging}`;
    await $`mkdir -p ${staging}`;
    await $`cp -r ${PLATFORM_DIR}/bin ${staging}/`;
    await $`cp ${PLATFORM_DIR}/install.sh ${staging}/`;
    await $`cp ${PLATFORM_DIR}/capsper-update.sh ${staging}/`;
    await $`cp dist/shared/install-common.sh ${staging}/`;
    await $`cp ${PLATFORM_DIR}/VERSION ${staging}/`;
    await $`tar -czf ${TARBALL} -C ${staging} .`;
    await $`shasum -a 256 ${TARBALL} > ${TARBALL}.sha256`;
    await $`rm -rf ${staging}`;
    console.log(`Tarball: ${TARBALL} (v${ver})`);
}

export async function sign() {
    ensureBinary();
    if (!existsSync(TARBALL)) {
        console.error(`Tarball not found: ${TARBALL} — run dist first`);
        process.exit(1);
    }

    const hasOidc = !!process.env.ACTIONS_ID_TOKEN_REQUEST_URL;

    // macOS: sign the Mach-O binary with Fulcio cert
    if (IS_MACOS) {
        console.log("Signing macOS binary with Fulcio...");
        await $`fulcio-codesign --identifier io.github.danielbodart.capsper --subject io.github.danielbodart.capsper --entitlements dist/macos/entitlements.plist ${PLATFORM_DIR}/bin/capsper`;
        // Re-create tarball with signed binary
        await distMacOS();
    }

    // Both platforms: sign the tarball with cosign for provenance
    if (hasOidc) {
        console.log(`Signing ${TARBALL} with cosign...`);
        await $`cosign sign-blob ${TARBALL} --bundle ${TARBALL}.sigstore.json --yes`;
        if (!IS_MACOS && existsSync(DEPS_TARBALL)) {
            console.log(`Signing ${DEPS_TARBALL} with cosign...`);
            await $`cosign sign-blob ${DEPS_TARBALL} --bundle ${DEPS_TARBALL}.sigstore.json --yes`;
        }
    } else {
        console.log("Skipping cosign blob signing (no OIDC token — not in CI)");
    }
}

export async function lint() {
    await $`shellcheck dist/linux/*.sh dist/macos/*.sh dist/shared/*.sh bootstrap.sh scripts/*.sh`;
}

export async function ci() {
    await ensureDeps();
    const ver = await version();
    console.log("Running lint...");
    await $`shellcheck dist/linux/*.sh dist/macos/*.sh dist/shared/*.sh scripts/*.sh bootstrap.sh`;
    console.log("Running tests...");
    await $`zig build test`;
    await build();
    await dist();
    await sign();
    if (process.env.GH_TOKEN) {
        const noCreateRelease = process.env.NO_CREATE_RELEASE === "true";
        // Collect all release assets (deps tarball only exists for Linux)
        const assets = [TARBALL, `${TARBALL}.sha256`];
        if (existsSync(`${TARBALL}.sigstore.json`)) {
            assets.push(`${TARBALL}.sigstore.json`);
        }
        if (!IS_MACOS && existsSync(DEPS_TARBALL)) {
            assets.push(DEPS_TARBALL, `${DEPS_TARBALL}.sha256`);
            if (existsSync(`${DEPS_TARBALL}.sigstore.json`)) {
                assets.push(`${DEPS_TARBALL}.sigstore.json`);
            }
        }
        if (noCreateRelease) {
            console.log(`Uploading assets to release v${ver}...`);
            for (let attempt = 1; attempt <= 10; attempt++) {
                const { exitCode } = await $`gh release upload v${ver} ${assets} --clobber`.nothrow();
                if (exitCode === 0) break;
                if (attempt === 10) {
                    console.error(`Failed to upload after ${attempt} attempts`);
                    process.exit(1);
                }
                console.log(`Release not ready yet (attempt ${attempt}/10), waiting 30s...`);
                await Bun.sleep(30_000);
            }
        } else {
            const commitMsg = (await $`git log -1 --format=%B`.quiet()).text().trim();
            console.log(`Creating release v${ver}...`);
            await $`gh release create v${ver} ${assets} --title v${ver} --notes ${commitMsg}`;
        }
    }
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}


/** Verify the Nix flake: both packages build from source, and the NixOS module
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
    // test. Both packages are cheap: capsper itself is a zig build, and the
    // CUDA execution provider is fetched rather than compiled.
    await $`nix flake check --print-build-logs`;
    await $`nix build --no-link .#capsper-cpu .#capsper-cuda`;
}
const commands: Record<string, Function> = {
    dev, build, clean, setup, test, lint, dist, sign, ci, nix, version: printVersion,
    "short-test": shortTest,
    "medium-test": mediumTest,
    "long-test": longTest,
    "slow-test": slowTest,
    // Deliberately in no aggregate above: it plays sound out loud through the
    // real speakers and records the real microphone, so it runs when a person
    // asks for it by name and at no other time.
    "manual-echo-test": manualEchoTest,
};

const command = process.argv[2] || "dev";
const args = process.argv.slice(3);

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
