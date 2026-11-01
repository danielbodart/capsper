#!/usr/bin/env bash
# The Linux release tarball, as `mise run dist` made it, installed as
# install.sh installs it, into a scratch home: its files laid out by
# install_files, the binary there saying its version,
# and the user units install.sh writes (the service with auto-updates and
# rollback, the update timer and its service, the rollback service)
# verified by systemd-analyze against the installed programs. install.sh's
# own main is interactive and downloads the speech model, so this takes its
# functions and calls the ones that lay files down, with systemctl a no-op.
set -euo pipefail

CDPATH='' cd "$(dirname "$0")/.."
tarball=capsper-linux-x86_64.tar.gz
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(sha256sum -c "$tarball.sha256")
src=$work/src
mkdir -p "$src" "$work/home"
tar -C "$src" -xzf "$tarball"

export HOME=$work/home XDG_DATA_HOME=$work/home/.local/share XDG_CONFIG_HOME=$work/home/.config
systemctl() { :; }
# shellcheck source=/dev/null
source <(sed -e '/^# ─── Main/,$d' -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=$src|" "$src/install.sh")

install_files
version=$(cat "$src/VERSION")
bin=$INSTALL_DIR/current/bin/capsper
said=$("$bin" --version 2>&1)
[[ $said =~ ^capsper\ 0\.[0-9]+\.[0-9]+$ ]] || { echo "dist-check: $bin --version said '$said'" >&2; exit 1; }
[ -f "$INSTALL_DIR/current/models/silero_vad.onnx" ]
[ -f "$INSTALL_DIR/lib/libonnxruntime.so" ]

install_service "$INSTALL_DIR" "$bin" FL "$INSTALL_DIR/models" "" true
install_update_timer
install_rollback_service
units=$XDG_CONFIG_HOME/systemd/user
grep -qx "ExecStart=$bin --trigger capslock --audio-channel FL --model $INSTALL_DIR/models/nemotron" "$units/capsper.service"
systemd-analyze --user verify "$units/capsper.service" "$units/capsper-update.service" "$units/capsper-update.timer" "$units/capsper-rollback.service"
echo "$tarball (v$version) installs and its units verify."
