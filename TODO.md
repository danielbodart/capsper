# TODO — Whisper Dictation Roadmap

Full roadmap for making whisper-dictate production-ready for public use.

## 1. Fix Critical Documentation Issues

- [ ] **Rewrite README.md** — currently describes the old Python/SimulStreaming architecture. Needs to reflect Zig rewrite, actual build steps, and correct setup flow.
- [ ] **Fix `run.sh` claims** — README says `run.sh` downloads models; it doesn't. Either add model download to `run.sh` or fix the docs.

## 2. Model Management

- [ ] **Add model download script** — `download-models.sh` that wraps whisper.cpp's download scripts for both the Whisper model and VAD model. Single command: `./download-models.sh`
- [ ] **Check models on startup** — if model file doesn't exist, print a clear error with the exact download command instead of a cryptic "Failed to load model"
- [ ] **Support XDG paths** — look for models in `~/.local/share/whisper-dictate/models/` as a fallback, not just relative paths from cwd
- [ ] **Add `--download-model` flag** — optional: let the binary itself download models (`whisper-dictate --download-model`)

## 3. CLI Improvements

- [ ] **Add `--help` / `-h` flag** — currently any unknown arg shows usage, but `--help` isn't explicitly handled
- [ ] **Add `--version` flag** — print version, whisper.cpp commit, model info
- [ ] **Add `--threads` / `-t` flag** — thread count is hardcoded to 4 in main.zig and server.zig
- [ ] **Add `--log-level` flag** — support silent/normal/verbose; currently always verbose debug output
- [ ] **Add `--check` flag** — validate setup: model files exist, GPU available, audio tools installed
- [ ] **Add `--language` / `-l` flag** — currently hardcoded to English in pipeline.zig
- [ ] **Add `--flash-attn` flag** — flash attention is hardcoded to `false` in main.zig despite CMake building with it
- [ ] **Expose VAD thresholds** — `--vad-threshold` for noisy environments
- [ ] **Expose transcription interval** — `--interval` to control how frequently transcription runs (currently hardcoded in server.zig)
- [ ] **Expose max buffer duration** — `--max-buffer` (currently 15s hardcoded)

## 4. Error Messages & User Feedback

- [ ] **Print model path on load failure** — "Failed to load model: /path/to/model.bin — file not found. Download with: ./download-models.sh"
- [ ] **Print VAD model path on failure** — same pattern as above
- [ ] **Make warmup failure non-fatal** — currently returns (exits) on warmup failure despite printing "Warning"
- [ ] **Add startup summary** — after model load, print: model name, GPU status, port, thread count
- [ ] **Add `notify-send` integration to whisper.sh** — desktop notification when recording starts/stops (like Voxtype does)
- [ ] **Log server crashes to stderr** — distinguish between recoverable (client disconnect) and fatal (OOM, GPU error)

## 5. Configuration

- [ ] **Config file support** — `~/.config/whisper-dictate/config.toml` or similar, for persistent settings
- [ ] **Pass server args from whisper.sh** — currently whisper.sh hardcodes `--port 43007`, doesn't expose `--threads`, `--model`, etc.
- [ ] **Environment variable overrides** — `WHISPER_MODEL`, `WHISPER_PORT`, `WHISPER_THREADS` etc. in whisper.sh

## 6. Setup & Installation

- [ ] **Add submodule check** — `run.sh` and/or `build.zig` should detect if whisper.cpp submodule is empty and print `git submodule update --init --recursive`
- [ ] **Add CUDA check** — verify NVIDIA GPU and CUDA toolkit are available before attempting build
- [ ] **Add jfk.wav to repo or auto-download** — referenced everywhere for warmup but not committed (or make `--no-warmup` the default if no warmup file found)
- [ ] **Commit test-compare.sh** — currently untracked
- [ ] **Add testdata/ or auto-download** — `testdata/long-recording.wav` and `.txt` are needed for comparison tests but not in repo

## 7. Build System

- [ ] **Support building without CUDA** — add a `build.zig` option like `-Dcuda=false` for CPU-only builds (broader hardware support)
- [ ] **Suppress CMake output** — build is very noisy; pipe to log file or only show on error
- [ ] **Add install step** — `zig build install` should copy binary + shared libs to a prefix
- [ ] **Bundle shared libs with binary** — use `$ORIGIN/../lib` rpath so binary can be relocated with its .so files

## 8. CI/CD — GitHub Actions

- [ ] **Add basic CI workflow** — on push/PR: checkout with submodules, install mise, `mise install`, `mise exec zig -- zig build test` (mirrors local setup exactly)
- [ ] **Cache mise and CMake** — cache `~/.local/share/mise/` and `whisper.cpp/build-zig/` between runs
- [ ] **Add integration test job** — requires CUDA runner; may need self-hosted or skip initially
- [ ] **Add release workflow** — on tag push: build binary, bundle with shared libs, upload as GitHub Release artifact
- [ ] **Release tarball format**:
  ```
  whisper-dictate-linux-x64-cuda12.tar.gz
  ├── bin/whisper-dictate
  ├── lib/libwhisper.so, libggml*.so
  ├── whisper.sh
  ├── download-models.sh
  └── install.sh
  ```
- [ ] **Add build matrix** — consider CPU-only and CUDA variants

## 9. Packaging & Distribution

- [ ] **Create install.sh** — for tarball releases: checks system deps, downloads models, creates systemd service
- [ ] **AUR package** — Arch Linux is popular with the target audience
- [ ] **Debian package (.deb)** — longer term; declare apt dependencies properly
- [ ] **AppImage** — bundle binary + shared libs in single file (still needs CUDA system libs)

## 10. Code Quality

- [ ] **Move hardcoded constants to config struct** — transcription interval, silence timeout, max buffer, thread count (server.zig lines 11-16)
- [ ] **Add `--help` examples** — show common usage patterns in help text
- [ ] **Consistent logging** — use `std.log` everywhere instead of mix of `std.debug.print` and `std.log.warn`
- [ ] **Validate model file exists before loading** — `std.fs.cwd().access(path)` before calling whisper_init

## 11. Future Features (Nice to Have)

- [ ] **Timeout/auto-stop** — `--timeout 10` to auto-stop after N seconds of silence (like nerd-dictation)
- [ ] **Stdout mode** — `--stdout` to print transcription to stdout instead of requiring xdotool (useful for testing, piping)
- [ ] **Multiple language support** — expose whisper's multilingual capability
- [ ] **Beam search option** — `--beam-size N` for higher accuracy at cost of latency
- [ ] **Profile switching** — `--profile low-latency` vs `--profile high-accuracy` presets
- [ ] **Clipboard mode** — type text via clipboard paste instead of xdotool (works around some app input issues)
- [ ] **Systemd socket activation** — start server on demand when first connection arrives

## Priority Order

If implementing incrementally:

1. Fix README (critical — currently misleading)
2. Model download script + startup checks (biggest UX pain point)
3. `--help`, `--version`, `--threads` (low effort, high value)
4. Basic GitHub Actions CI (unit + property tests)
5. Better error messages
6. Config passthrough in whisper.sh
7. Release workflow + tarball packaging
8. Everything else
