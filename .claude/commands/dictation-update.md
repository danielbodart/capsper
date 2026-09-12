# Dictation Update

Monitor CI, then get the newly built capsper running locally.

## Steps

1. **Detect platform**:
   - macOS if `uname -s` is `Darwin`.
   - **NixOS** if `grep -q '^ID=nixos' /etc/os-release` — capsper is built from source via the flake, so it does NOT use the release tarball or the update script. Follow the NixOS section below instead of steps 4-7.
   - Otherwise Linux (tarball install).

2. **Wait for CI**: Find the latest CI run on the current branch with `gh run list --limit 1 --branch <current-branch>`. Watch it with `gh run watch <run-id>` until it completes.

3. **CI failed?** If the run failed, show the failure logs with `gh run view <run-id> --log-failed` and stop. Tell the user what failed so they can fix it.

4. **Trigger update**: Run `~/.local/share/capsper/capsper-update.sh`. This checks GitHub Releases, downloads the latest if newer, verifies SHA256, and stages it. If output says "Already up to date", tell the user no new release is available yet (CI may not have created a release for this branch) and stop.

5. **Restart service**:
   - **Linux**: Run `systemctl --user restart capsper.service` and wait 2 seconds.
   - **macOS**: Run `launchctl bootout gui/$(id -u)/io.github.danielbodart.capsper 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.danielbodart.capsper.plist` and wait 2 seconds.

6. **Verify**:
   - Check service is running:
     - **Linux**: `systemctl --user status capsper.service` (should be "active (running)")
     - **macOS**: `launchctl print gui/$(id -u)/io.github.danielbodart.capsper 2>&1 | head -5` (should show the service)
   - Confirm new version: `~/.local/share/capsper/current/bin/capsper --version 2>&1`

7. **Restart failed?**
   - **Linux**: Show recent journal logs with `journalctl --user -u capsper.service -n 30 --no-pager`
   - **macOS**: Show recent logs with `tail -30 ~/.local/share/capsper/capsper.log`
   - Tell the user the update was applied but the service failed to start.

## NixOS

There is no release tarball, no update script and no staged swap. The flake input
tracks the capsper repository's default branch, so updating is moving the lock
forward and rebuilding. The commit must be **pushed** for the flake to see it.

1. **Wait for CI** — steps 2 and 3 above apply unchanged. Do not rebuild on a red build.

2. **Find the config repo**: `dirname "$(readlink -f /etc/nixos/flake.nix)"` (normally `~/Projects/nix-config`). Run everything below from there.

3. **Record the locked revision** before updating:
   ```sh
   nix flake metadata --json | jq -r '.locks.nodes.capsper.locked.rev'
   ```

4. **Update just capsper**: `nix flake update capsper`

5. **Nothing moved?** Re-read the locked rev. If it is unchanged, the pushed commit is already locked — tell the user and stop. If it changed but does not match the capsper commit you expect, the commit is probably unpushed; say so.

6. **Rebuild**: `sudo nixos-rebuild switch`. This builds capsper from source, so give it several minutes. No `--flake` and no `#host` — `/etc/nixos/flake.nix` symlinks to the repo and the configuration name defaults to the hostname.

   **Just run `sudo`. Never ask the user for a password, and never hand the command back for them to run themselves.** The `graphical-sudo` plugin sets `SUDO_ASKPASS`, and sudo execs that helper for the password whenever it has no terminal — which is always the case here. A dialog appears on the user's desktop and they approve it there. Do not add `-n`: that disables exactly this mechanism and fails with "a password is required".

7. **Verify the service picked it up**:
   ```sh
   systemctl --user show capsper.service -p ExecStart --no-pager
   systemctl --user is-active capsper.service
   ```
   The store path must contain the new short revision (`capsper-cpu-0.0.0-git.<rev>`). home-manager may leave the old process running; if the path is stale, run `systemctl --user restart capsper.service`.

8. **Rebuild or restart failed?** Show `journalctl --user -u capsper.service -n 30 --no-pager`. Roll back with `sudo nixos-rebuild switch --rollback`.

9. **Tell the user the lock is dirty.** `flake.lock` in nix-config is now modified and uncommitted, exactly as if they had run the commands by hand. Committing and pushing it is theirs to do — do not commit it for them.

## Notes

- The update script handles everything: GitHub API check, download, SHA256 verification, staging
- **Linux**: The actual version swap happens via `capsper-apply-update.sh` which runs as `ExecStartPre=` in the systemd service
- **macOS**: The version swap happens on next service start (the update script stages the release)
- **NixOS**: Built from source, so there is no release, no SHA256 to verify and no rollback timer. Models are not in the nix store — they stay in `~/.local/share/capsper/models` and a rebuild does not touch them.
- If the service crashes after update, the rollback service will automatically revert within 5 minutes (tarball Linux only; macOS and NixOS require a manual rollback)
