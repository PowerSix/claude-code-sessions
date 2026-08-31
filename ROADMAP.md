# Roadmap

## Zip-then-recycle: give `-Delete` an undo

**Idea:** before removing anything, archive every file selected for deletion into
a single zip, delete the originals, then send that zip to the **Recycle Bin**
rather than deleting it outright. The bin becomes a free restore point, and
Windows already manages and auto-purges it, so no bespoke retention logic is
needed. Restoring a session becomes "undelete the zip, extract it back".

Right now `-Delete` is permanent by design and the only safety net is the
confirmation prompt. This would make a mis-typed selector recoverable, which
matters most for the exact mistake the tool invites: `-Delete 3` when you meant
`-Delete 30`.

**Sketch:**

1. Build the file list from the existing delete plan (transcript + sidecar +
   `file-history` + `session-env` + `tasks` + `jobs` + `%TEMP%\claude`).
2. Zip it preserving enough path structure to restore it, e.g. entries named
   `projects/<proj>/<uuid>.jsonl`, `file-history/<uuid>/...`.
3. Delete the originals with the existing `Remove-PathHard`.
4. Send the zip to the Recycle Bin.
5. Report the zip name so it can be found in the bin.

### Gotchas to design around

These are already-verified facts, not speculation. Each one can silently break
this feature.

- **`Remove-Item` never uses the Recycle Bin.** There is no PowerShell-native
  recycle. Options: `Microsoft.VisualBasic.FileIO.FileSystem::DeleteFile($p,
  'OnlyErrorDialogs', 'SendToRecycleBin')` (needs the `Microsoft.VisualBasic`
  assembly), or the shell `IFileOperation` COM interface with `FOF_ALLOWUNDO`.
  Verify whichever is chosen actually lands the file in the bin instead of
  hard-deleting it, because both can silently fall back.
- **Build the zip outside any cloud-synced tree.** `.claude\projects` may be a
  junction into a cloud-synced folder, in which case a zip created there would
  upload and then immediately be deleted again: pure sync churn, and possibly a
  cloud-side tombstone. Build it in `%TEMP%` (local `C:`) and recycle it from
  there.
- **Files-On-Demand will force a hydration download.** When the projects tree is
  cloud-synced, its directories can be `ReadOnly + ReparsePoint` placeholders.
  Zipping a dehydrated file makes the sync client download it first, so
  archiving a large sidecar (tens of MB is normal for a session that ran many
  subagents) can stall noticeably or fail while offline. Decide whether to
  hydrate deliberately, skip cloud-only files, or warn.
- **`ReadOnly` must be cleared on the directory itself, not just its children.**
  Otherwise the post-zip delete fails with access-denied. `Remove-PathHard`
  already does this; any new deletion path must too.
- **The Recycle Bin has a per-volume size quota.** Windows silently *permanently*
  deletes items too large for it, which would turn "safe undo" into a lie. A
  bulk `-Delete *` sweep can easily produce a zip larger than the quota. Check
  the size and warn, or fall back to leaving the zip on disk and saying so.
- **Do not archive `memory\`, `history.jsonl`, `.claude.json` or `paste-cache\`.**
  `-Delete` never touches them, so they must not end up in the zip either or a
  restore could clobber current state with stale copies.
- **Duplicate UUIDs.** The same UUID can be a root transcript in two project
  dirs, sharing one sidecar. The zip must not contain the shared footprint twice,
  and a partial restore must not resurrect a sidecar whose transcript is still
  live.

### Open questions

- One zip per `-Delete` invocation, or one per session? Per invocation is simpler
  and matches the single confirmation; per session makes selective restore easier.
- Naming: `claude-sessions-<timestamp>-<n>sessions.zip` is findable in the bin,
  but the bin sorts by original location, so a stable parent folder may read
  better.
- Should there be a `-NoBackup` escape hatch for genuinely huge sweeps, or does
  that just reintroduce the footgun the feature exists to remove?
