# Backup and recovery

Settings › Backup & costs creates an unencrypted `.piopiobackup` directory. Choose a private location outside
Piopio's data folder. The app stops the engine, copies its offline data, verifies SHA-256 checksums and restarts.
Current work stops and pending Build prompts are cancelled. Keep external pi CLI sessions idle during backup;
an incomplete external session record causes the backup to fail instead of silently losing history.

Included: chats and notebook databases/files, local agent databases/memory and definition folders (including
history), Build conversation files, engine settings, UI preferences, drafts, request receipts and additional-cost
history. A referenced missing file or symbolic link causes a visible error. The app does not follow symbolic
links into other folders. Complete engine data is copied, including any engine-managed isolated working copies.

Excluded: engine authentication tokens/sockets/locks, logs, rebuildable search indexes, macOS Keychain secrets,
external source project folders and remote memory services. Provider/connector metadata may be restored, but
sign-ins may need reconnecting on another Mac. MCP/provider settings or conversation files may contain secrets
entered by the user: the backup itself is personal, sensitive data, even though Keychain secrets are not exported.
The development-only custom engine executable preference is not restored.

Restore verifies every file before stopping the engine or changing data. It stages a new data folder, remaps
internal paths and recovered definition/conversation paths, then swaps the verified folder into place. Restored Build histories use isolated copies; existing CLI session files remain untouched and are not imported again as duplicates. External
project paths remain external; add the folders again if they moved to another Mac. Credentials stay in Keychain.
The previous data folder is retained alongside the restored folder as `Piopio-before-restore-<id>`; use Show in
Finder after restore to locate it. Failures during the swap put the previous folder back. Reopen the app to reload
all interface preferences. Agents resume their saved schedules after the engine restarts.

The manifest verifies corruption and completeness; it is not a signature proving who made the backup. Restore
only backups you trust. Old pending approvals whose actions were completed outside the restored snapshot must
be reviewed before approving them again.
