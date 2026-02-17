# Dictation Update

Monitor CI, trigger the auto-update, and restart the capsper service.

## Steps

1. **Wait for CI**: Find the latest CI run on the current branch with `gh run list --limit 1 --branch <current-branch>`. Watch it with `gh run watch <run-id>` until it completes.

2. **CI failed?** If the run failed, show the failure logs with `gh run view <run-id> --log-failed` and stop. Tell the user what failed so they can fix it.

3. **Trigger update**: Run `~/.local/share/capsper/capsper-update.sh`. This checks GitHub Releases, downloads the latest if newer, verifies SHA256, and stages it. If output says "Already up to date", tell the user no new release is available yet (CI may not have created a release for this branch) and stop.

4. **Restart service**: Run `systemctl --user restart capsper.service` and wait 2 seconds.

5. **Verify**: Check that the service is running with `systemctl --user status capsper.service` (should be "active (running)") and confirm the new version with `~/.local/share/capsper/current/bin/capsper --version 2>&1`.

6. **Restart failed?** If the service is not active, show recent journal logs with `journalctl --user -u capsper.service -n 30 --no-pager` for diagnosis. Tell the user the update was applied but the service failed to start.

## Notes

- The update script handles everything: GitHub API check, download, SHA256 verification, staging
- The actual version swap happens via `capsper-apply-update.sh` which runs as `ExecStartPre=` in the systemd service
- If the service crashes after update, the rollback service will automatically revert within 5 minutes
