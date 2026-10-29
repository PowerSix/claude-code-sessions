# Roadmap

## Zip-then-recycle: give `-Delete` an undo

**Idea:** before removing anything, archive every file selected for deletion into
a single zip, delete the originals, then send that zip to the **Recycle Bin**
rather than deleting it outright. The bin becomes a free restore point, and
Windows already manages and auto-purges it, so no bespoke retention logic is
needed. Restoring a session becomes "undelete the zip, extract it back".

Right now deletion is permanent by design. The plan shows each target's first
prompt before asking, which catches most wrong-index mistakes before they
happen, but once you answer there is no way back. This would make a mis-typed
selector recoverable, which matters most for the exact mistake the tool
invites: `-Delete 3` when you meant `-Delete 30`.

It should cover `-Orphans -Delete` too. That is where memory gets removed in
bulk, and memory is the one thing in these stores that cannot be regenerated.

**Sketch:**

1. Run the existing plan and prompt unchanged.
2. After the answer, take the paths the executor is about to remove, AFTER its
   re-check against the disk. That re-check can drop paths (a session that
   started meanwhile, a leftover that stopped being an orphan), so the zip must
   be built from what actually goes, not from what the plan showed. Depending on
   the answer that is up to three sets: the footprint (`yes`), the leftovers
   (`all`), and the dirs left empty.
3. Zip it preserving enough path structure to restore it, e.g. entries named
   `projects/<proj>/<uuid>.jsonl`, `file-history/<uuid>/...`,
   `temp/<proj>/<uuid>/...`.
4. Delete the originals with the existing `Remove-PathHard`, which also keeps
   its protected-path guard.
5. Send the zip to the Recycle Bin.
6. Report the zip name so it can be found in the bin.

### Gotchas to design around

These are already-verified facts, not speculation. Each one can silently break
this feature.

- **`Remove-Item` never uses the Recycle Bin.** There is no PowerShell-native
  recycle. Options: `Add-Type -AssemblyName Microsoft.VisualBasic`, then
  `[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')`,
  or the shell `IFileOperation` COM interface with `FOF_ALLOWUNDO`. Verify
  whichever is chosen actually lands the file in the bin instead of
  hard-deleting it, because both can silently fall back.
- **Build the zip outside any cloud-synced tree.** `.claude\projects` may be a
  junction into a cloud-synced folder, in which case a zip created there would
  upload and then immediately be deleted again: pure sync churn, and possibly a
  cloud-side tombstone. Build it in `%TEMP%` (local `C:`) and recycle it from
  there, outside `%TEMP%\claude` so the orphan scan never sees it.
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
- **Archive exactly what is removed, and nothing else.** `memory\` IS removed,
  by `all` (when it was the folder's last session) and by `-Orphans -Delete`,
  and it is the most valuable thing in the zip. `history.jsonl`, `.claude.json`
  and `paste-cache\` are never removed by any mode, so they must never be
  archived either, or a restore would clobber current state with stale copies.
- **One session can own several sidecars.** A sidecar lands under whichever
  project dir the cwd mapped to when the tool ran, so one UUID can have a
  sidecar in more than one project dir. Each entry must keep its own project
  dir in the zip path, or a restore merges them into the wrong place.
- **Duplicate UUIDs.** The same UUID can be a root transcript in two project
  dirs, sharing one footprint. The zip must not contain the shared footprint
  twice, and a partial restore must not resurrect a sidecar whose transcript is
  still live.
- **A failed delete must not leave a zip that claims it happened.** The
  executor already keeps a session's other data when its transcript cannot be
  deleted; the zip should then hold only what was really removed, or the
  restore instructions will lie.

### Open questions

- One zip per `-Delete` invocation, or one per session? Per invocation is simpler
  and matches the single confirmation; per session makes selective restore easier.
- Naming: `claude-sessions-<timestamp>-<n>sessions.zip` is findable in the bin,
  but the bin sorts by original location, so a stable parent folder may read
  better.
- Should there be a `-NoBackup` escape hatch for genuinely huge sweeps, or does
  that just reintroduce the footgun the feature exists to remove?
