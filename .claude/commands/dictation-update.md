# Dictation Update

Monitor CI, trigger the auto-update, and restart the capsper service.

## Steps

1. **Detect platform**: Check `uname -s` to determine if we're on Linux or macOS.

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

## Notes

- The update script handles everything: GitHub API check, download, SHA256 verification, staging
- **Linux**: The actual version swap happens via `capsper-apply-update.sh` which runs as `ExecStartPre=` in the systemd service
- **macOS**: The version swap happens on next service start (the update script stages the release)
- If the service crashes after update, the rollback service will automatically revert within 5 minutes (Linux only; macOS requires manual rollback)
