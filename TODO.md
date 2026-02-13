# TODO — Whisper Dictation Roadmap

Full roadmap for making whisper-dictate production-ready for public use.

## 1. Documentation

- [x] **Rewrite README.md** — updated to reflect PipeWire capture, `run.ts` task runner, correct setup flow
- [x] **Fix `run.sh` claims** — `run.sh` replaced by `run.ts` task runner

## 2. Model Management

- [ ] **Add model download to `run.ts`** — `./run download-models` that wraps whisper.cpp's download scripts for both the Whisper model and VAD model
- [ ] **Check models on startup** — if model file doesn't exist, print a clear error with the exact download command instead of a cryptic "Failed to load model"
- [ ] **Support XDG paths** — look for models in `~/.local/share/whisper-dictate/models/` as a fallback, not just relative paths from cwd

## 3. CLI Improvements

- [ ] **Add `--help` / `-h` flag** — currently any unknown arg shows usage, but `--help` isn't explicitly handled
- [ ] **Add `--version` flag** — print version, whisper.cpp commit, model info
- [ ] **Add `--threads` / `-t` flag** — thread count is hardcoded to 4 in pipeline.zig
- [ ] **Add `--log-level` flag** — support silent/normal/verbose; currently always verbose debug output
- [ ] **Add `--check` flag** — validate setup: model files exist, GPU available, PipeWire running
- [ ] **Add `--language` / `-l` flag** — currently hardcoded to English in pipeline.zig
- [ ] **Add `--flash-attn` flag** — flash attention is hardcoded to `false` in main.zig despite CMake building with it
- [ ] **Expose VAD thresholds** — `--vad-threshold` for noisy environments
- [ ] **Expose transcription interval** — `--interval` to control how frequently transcription runs (currently 1s hardcoded in server.zig)
- [ ] **Expose max buffer duration** — `--max-buffer` (currently 15s hardcoded)

## 4. Error Messages & User Feedback

- [ ] **Print model path on load failure** — "Failed to load model: /path/to/model.bin — file not found. Download with: ./run download-models"
- [ ] **Print VAD model path on failure** — same pattern as above
- [ ] **Make warmup failure non-fatal** — currently returns (exits) on warmup failure despite printing "Warning"
- [ ] **Add startup summary** — after model load, print: model name, GPU status, port, input mode, PipeWire channel
- [ ] **Add `notify-send` integration to whisper.sh** — desktop notification when recording starts/stops
- [ ] **Log server crashes to stderr** — distinguish between recoverable (client disconnect) and fatal (OOM, GPU error)

## 5. Configuration

- [ ] **Config file support** — `~/.config/whisper-dictate/config.toml` or similar, for persistent settings
- [ ] **Environment variable overrides** — `WHISPER_MODEL`, `WHISPER_PORT`, `WHISPER_THREADS` etc. in whisper.sh

## 6. Setup & Installation

- [x] **Add submodule check** — `run.ts` `ensureSubmodule()` handles this
- [ ] **Add CUDA check** — verify NVIDIA GPU and CUDA toolkit are available before attempting build
- [ ] **Add jfk.wav to repo or auto-download** — referenced everywhere for warmup but not committed (or make `--no-warmup` the default if no warmup file found)
- [x] **Commit test scripts** — test-stream, test-compare, test-pw-stream all in `run.ts`

## 7. Build System

- [ ] **Support building without CUDA** — add a `build.zig` option like `-Dcuda=false` for CPU-only builds (broader hardware support)
- [ ] **Suppress CMake output** — build is very noisy; pipe to log file or only show on error
- [ ] **Add install step** — `zig build install` should copy binary + shared libs to a prefix
- [ ] **Bundle shared libs with binary** — use `$ORIGIN/../lib` rpath so binary can be relocated with its .so files

## 8. CI/CD — GitHub Actions

- [ ] **Add basic CI workflow** — on push/PR: checkout with submodules, install mise, `mise install`, `mise exec zig -- zig build test` (mirrors local setup exactly)
- [ ] **Cache mise and CMake** — cache mise tools and `whisper.cpp/build-zig/` between runs
- [ ] **Add integration test job** — requires CUDA runner; may need self-hosted or skip initially
- [ ] **Add release workflow** — on tag push: build binary, bundle with shared libs, upload as GitHub Release artifact
- [ ] **Add build matrix** — consider CPU-only and CUDA variants

## 9. Packaging & Distribution

- [ ] **Create install.sh** — for tarball releases: checks system deps, downloads models, creates systemd service
- [ ] **AUR package** — Arch Linux is popular with the target audience
- [ ] **Debian package (.deb)** — longer term; declare apt dependencies properly

## 10. Code Quality

- [ ] **Move hardcoded constants to config struct** — transcription interval, silence timeout, max buffer, thread count (server.zig lines 11-16)
- [ ] **Consistent logging** — use `std.log` everywhere instead of mix of `std.debug.print` and `std.log.warn`
- [ ] **Validate model file exists before loading** — `std.fs.cwd().access(path)` before calling whisper_init

## 11. Future Features (Nice to Have)

- [ ] **Timeout/auto-stop** — `--timeout 10` to auto-stop after N seconds of silence
- [ ] **Multiple language support** — expose whisper's multilingual capability
- [ ] **Beam search option** — `--beam-size N` for higher accuracy at cost of latency
- [ ] **Profile switching** — `--profile low-latency` vs `--profile high-accuracy` presets
- [ ] **Clipboard mode** — type text via clipboard paste instead of xdotool (works around some app input issues)
- [ ] **Systemd socket activation** — start server on demand when first connection arrives
- [ ] **TCP input deprecation** — consider removing TCP mode entirely since PipeWire local mode is simpler and lower latency

## Priority Order

If implementing incrementally:

1. Model download command + startup checks (biggest UX pain point)
2. `--help`, `--version`, `--threads` (low effort, high value)
3. Basic GitHub Actions CI (unit + property tests)
4. Better error messages
5. Config file support
6. Release workflow + tarball packaging
7. Everything else
