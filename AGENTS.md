# External SSD plan and SSD Monitor: the agent guide

This is the complete technical guide for coding agents (Codex reads this file; Claude Code reads it through
`CLAUDE.md`). `README.md` is the short version for people.

It covers two jobs:
1. **Helping a user move their Mac's developer data onto an external SSD**, the way the source Mac did it:
   sections 1–6, 9–12.
2. **Setting up or changing SSD Monitor**, the menu bar app in this repo, and its helper scripts: sections 7, 8
   and 13.

Read the whole guide before doing anything. Everything specific to the source Mac (paths, volume IDs, user
names, sizes, the tools it runs) is an example, not an instruction. Survey the Mac you are on (section 5),
propose a plan with sizes, and let your user decide.

**Ground rules:**
- **Ask the user first** before you:
  - erase a disk
  - delete an original folder
  - stop their programs
  - edit their dotfiles or shell config
- **`sudo` steps:** write the script, show it, run its `--dry-run`/`--check` without sudo, and let the user
  start it themselves (in Claude Code: `! sudo bash <script>`; in Codex, the user runs it in a terminal).
- **Keep a written record:** a README with a dated status table of every step and result. Keep a copy on the
  Mac's internal disk (for example `~/Local/ssd/README.md`), where it stays readable while the SSD is unplugged.
- **Test fix-mode changes only on scratch folders**, never on the user's real repos.

---

## 1. The requirement

- **The SSD stays plugged in.** It moves the big developer folders off the internal disk for good. It is not a
  backup or a removable work disk.
- **An unplug may interrupt work.** If the cable is knocked out, builds, git commands and dev servers working
  in those folders may fail. That is accepted.
- **After the replug, everything must resume.** Rerunning what failed must just work:
  - no reboot
  - no errors to fix by hand
  - no duplicate folders to merge
  - no hidden problems that show up later
- **Running Claude Code and Codex sessions must not have to quit**, neither for the migration nor after an
  unplug. Restarting them is a lot of work for the user.

Every design choice below follows from this. When in doubt, ask: "after a replug, would this need a manual
fix?" If yes, it stays on the internal disk.

## 2. Watch the internal disk's free space during the migration

**This almost went wrong on the source Mac.** Its internal free space fell from 24 GiB to **5.5 GiB within about
three hours**, in the middle of the migration. The cause was mostly **28 GB of swap files** (`sysctl
vm.swapusage`). Xcode, Android Studio, booted simulators, a dev stack, many agent sessions and the long copy
were all running at once. A Mac that runs out of disk mid-copy or mid-swap is a real risk: apps fail to save, and
a swap step can stop halfway.

Every Mac is different, so plan for it:
- **Free some space before you start.** Candidates: Xcode DerivedData, unused simulators and runtimes, old
  Android system images, package-manager caches. Measure first; delete only with the user's OK.
- **Watch the free space through every long step:** `df -h /System/Volumes/Data` and `sysctl vm.swapusage`.
  Agree on a threshold with the user (for example 15 GiB). Below it, stop starting new work and tell them.
- **Keep heavy apps closed** during the long steps when the user can. Quitting Android Studio and Xcode shrank
  swap within minutes on the source Mac.
- **The internal disk gains nothing until the swap.** The copy only fills the SSD, and originals are deleted only
  after the copy is verified. If space runs short, **swap the small folders first**. The source Mac swapped five
  small folders and Developer first, and `~/Repo` a few hours later, overnight.
- For long jobs, `caffeinate -i <command>` keeps the Mac awake.

## 3. What the source Mac ended up with

**Hardware.** A 1 TB NVMe SSD in a USB 10 Gb/s enclosure with a Realtek RTL9220 bridge, plugged **directly into
a port on the Mac**. A hub is slower and more likely to drop the disk after sleep.

**Layout.** One APFS container on the SSD (GUID, case-insensitive) with **one volume per folder**.
The volumes share the whole disk, so none has a fixed size. Each is mounted at the folder's **original path**
through `/etc/fstab`, by volume UUID, hidden from Finder with `nobrowse`:

| Volume | Mounted at | Freed on the Mac |
|---|---|---|
| Repo | `~/Repo` (all code; the bun cache too, at `~/Repo/.cache/bun`) | 109 GiB |
| Developer | `~/Library/Developer` (Xcode, simulators) | 83 GiB |
| Android | `~/Library/Android` (SDK) | 39 GiB, with AVD |
| AVD | `~/.android/avd` (emulators) | (with Android) |
| MobileSync | `~/Library/Application Support/MobileSync` (iPhone backups) | 14.5 GiB |
| Gradle | `~/.gradle` | 7.3 GiB |
| Downloads | `~/Downloads` | 1.6 GiB |

That is about 255 GiB freed. The Mac's free space went from 5.5 GiB at the low point to **299 GiB**.

**When the SSD is away**, each of those paths is an empty folder on the internal disk, owned by root with mode
`555`, so nothing can be written there by mistake (section 4).

**On the internal disk, in `~/Local`**, everything that must work while the SSD is unplugged:
- `~/Local/bin`: the helper scripts `ssd-resume`, `ssd-off`, `ssd-volumes.sh`
- `~/Local/ssd`: the zsh hook `ssd.zsh`, a copy of the setup's README, the helpers' state files
- the user's dotfiles repo, which used to live inside `~/Repo` (section 4)

**SSD Monitor** (this repo) watches the volumes and runs the recovery after a replug (section 7).

**An agent rule** in `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` tells agents to stop and ask for the replug
when they see an unplugged SSD (section 9).

## 4. Design decisions and why

**Mount at the original path; don't use symlinks.** A link like `~/Repo → /Volumes/SSD/Repo` looks simpler, but:
- **Claude Code identifies projects by the real, resolved path.** Through a link, project history and session
  names would split between two keys.
- **Apps replace a dangling link.** While the SSD is away, an app that finds a broken `~/Downloads` or
  `~/.gradle` link may create a real, empty folder in its place. After the replug there are two folders to merge.
- **After an unclean unplug, macOS may remount at `/Volumes/Repo 1`**, which breaks every link to
  `/Volumes/Repo`.

With mounts, every path stays exactly what it was, for every tool.

**Lock the empty mount points.** While the SSD is away, the mount points are ordinary empty folders. Tested with
a disk image: a program writing to `~/Repo/x/file.txt` at that moment **succeeds**, and the file lands on the
internal disk, hidden under the mount once the SSD is back. That is a silent duplicate.

The fix: each empty mount point is **owned by root with mode `555`**. Writes then fail with `Permission
denied`, and mounting over a `555` folder still works. The folders *on the SSD* keep the original owner and mode
(for example `~/Downloads` stays `700`); only the placeholder on the internal disk is locked.

**What stays on the internal disk.** The test is the requirement: would it need a manual fix after a replug?
- **Dotfiles and app configs.** On the source Mac the dotfiles repo lived inside `~/Repo`. It moved to
  `~/Local/<dotfiles repo>`, every link to it was repointed, and a link was left at the old path inside `~/Repo`.
  Many apps read their config at launch: window managers, keyboard remappers, launchers, terminals. With a dead
  link, some fall back to defaults or write a new file over the link, which needs a manual fix. New terminals
  would also open without `.zshrc`, and agents would lose their skills.
- **Agent state** (`~/.claude`, `~/.codex`): agents must keep working, and keep their rules, while the SSD is
  away.
- **The helper scripts and the app** (`~/Local/bin`, `/Applications`): they are what you need while it's away.
- **App data, `~/Library/Caches`, Mail, the rest of home**: apps expect them at all times. Not worth the risk.
- **Simulator runtimes** (`/Library/Developer/CoreSimulator/Volumes`): system-managed disk images with no
  supported way to put them elsewhere. The simulators' own data (`~/Library/Developer/CoreSimulator/Devices`)
  does move with Developer.
- **Command-line tools that live in a repo can move** with the code folder. Their commands fail while the SSD
  is away and work again after the replug, which fits the requirement. Keep their command links (in
  `~/.local/bin`, `~/.bun/bin`, …) on the internal disk.

**bun cache and APFS clones.** `bun install` makes each `node_modules` file an **APFS clone** of the file in its
cache. Clones share disk blocks, but only within one volume. So the bun cache lives **on the Repo volume**
(`BUN_INSTALL_CACHE_DIR=$HOME/Repo/.cache/bun`, set by `ssd.zsh` when a shell starts, and only if that folder
exists then; a shell started while the SSD was away uses bun's default cache until it is restarted). Any package
manager that links or clones from a shared store (pnpm, for example) needs its store on the same volume as the
projects too. **Copying turns clones into full copies:** the SSD needed about **374 GiB** for what took 255 GiB
on the Mac. Size the SSD with that in mind.

**Spotlight off on the cache-only volumes** (Developer, Android, AVD, Gradle, MobileSync), with `sudo mdutil -i
off <path>`:
- they hold nothing worth searching
- they hold over a million files that builds rewrite constantly
- the indexer keeps files open on indexed volumes, a common reason macOS refuses to eject a disk

Repo and Downloads stay indexed.

**Encryption is the user's choice; ask them.** An unencrypted SSD mounts by itself on every replug, but anyone
holding the drive can read the repos and their `.env` files. An encrypted volume must be unlocked before it
mounts, which conflicts with mounting by itself on replug unless its password is saved in the keychain.

## 5. Survey the Mac before proposing anything

1. **Disk and memory.**
   - `df -h /System/Volumes/Data`
   - `sysctl vm.swapusage`
   - the model and ports: `system_profiler SPHardwareDataType SPUSBHostDataType SPThunderboltDataType`
2. **Candidate folders and their real sizes.** Measure in a way that counts APFS clones once. `du` and Finder
   count every clone as a full copy and overstate what would be freed. The source Mac used `clone-size.ts` from
   the `reclaim` skill in the public GitHub repo `cevr/dotfiles` (`skills/reclaim/scripts/clone-size.ts`) for the
   freed sizes, and `du` for the space needed on the SSD.

   Typical candidates:
   - the code folder
   - `~/Downloads`
   - `~/Library/Developer`
   - `~/Library/Android`, `~/.android/avd`
   - `~/.gradle`
   - `~/Library/Application Support/MobileSync`
   - other large build caches, such as `~/.m2` or `~/.cargo`

   A folder qualifies when:
   - it is big
   - only tools that tolerate it vanishing use it
   - it is not needed at login before the SSD mounts
   - it does not hold config that apps rewrite
3. **What points into each candidate.** Look for:
   - symlinks under `~/.*`, `~/.config`, `~/.claude`, `~/.codex`, `~/Library/LaunchAgents` and
     `~/Library/Application Support` that resolve into it
   - hard-coded paths in `~/.zshrc` and in LaunchAgent plists

   A dotfiles repo or a tool that must work at login, living inside the code folder, has to move to `~/Local`
   first, with its links repointed.
4. **What runs from each candidate:** `lsof +c0 -nP` for working folders and open files. Include dev servers,
   watchers, VMs (Colima/Docker), emulators, simulators, Gradle daemons and browser-automation daemons; these must
   be stopped for the swap. Also note long-running helpers of agent sessions (MCP servers, REPL helpers) whose
   working folder is inside (section 6, step 5).
5. **SSD size.** It must cover the `du` size, plus room to grow.

Present the plan as a table: folder, freed on the Mac, space on the SSD, what stays internal, what must be stopped
for the swap, expected free space after.

## 6. Procedure

What the source Mac did, in order, with the checks its scripts had. **User** marks the steps that need the
user.

### 0. Backup first

Originals are deleted as soon as the SSD copy is verified, because there is no room to keep them. The source Mac
first made a full backup to a NAS:
- one compressed tar archive per folder
- each archive read back from the NAS, and its entry count compared with what was written

Lessons from it:
- **macOS `bsdtar` can write an archive it can't read back.** A file with a very large extended attribute (a
  multi-MB `com.apple.ResourceFork`) gives "Special header too large" on read, and every entry after it is lost.
  Scan for big xattrs before archiving. On the source Mac it was one disposable simulator download, excluded with
  the user's OK. On another Mac, list each such file and decide with the user: exclude it only if it is
  disposable; otherwise back it up another way that keeps its attributes (e.g. `ditto` to a disk).
- **Over SMB, stream one archive per folder** instead of copying millions of small files.

### 1. SSD setup

- **User** plugs the SSD directly into the Mac.
- Check the link speed in `system_profiler SPUSBHostDataType`. USB 2.0 would make the copy take many hours.
- Show `diskutil list external physical`. **User** confirms which disk it is.
- **Sleep test:** sleep the Mac for 2 minutes with the SSD attached, then check for "Disk Not Ejected Properly".
- **Erase it**, with the user's explicit OK naming the disk:
  - `diskutil eraseDisk APFS <FirstVolume> GPT diskN`
  - `diskutil apfs addVolume diskM APFS <Name>` for each other volume (`diskM` is the new container; see
    `diskutil apfs list`)
- As root:
  - `diskutil enableOwnership /Volumes/<Name>` for each volume
  - `chown <user>:staff /Volumes/<Name>` for each volume (enabling ownership leaves the volume root owned by
    root). Match the original folder's mode too: `~/Downloads` is `700`.
  - `mdutil -i off /Volumes/<Name>` for the cache-only volumes
- Record each volume's UUID: `diskutil info /Volumes/<Name> | grep 'Volume UUID'`. Disk IDs like `disk5s1`
  change between replugs; UUIDs don't.

### 2. First copy

Copy while the volumes are at `/Volumes/<Name>`; the user keeps working.
- **Before each copy, check the destination.** `/Volumes/<Name>` must be the mount point of the volume with the
  expected UUID (`diskutil info /Volumes/<Name>`). If the volume isn't mounted, `/Volumes/<Name>` could be a
  plain folder on the internal disk, or another disk with the same name. Abort if the check fails.
- Use **Homebrew rsync 3** (`brew install rsync`). macOS's `/usr/bin/rsync` is openrsync, which can't copy ACLs
  or creation dates.
- The command:
  ```
  rsync -aHAXN --sparse --no-specials --no-devices --numeric-ids --stats \
    --exclude=/.fseventsd --exclude=/.Spotlight-V100 --exclude=/.Trashes \
    --exclude=/.TemporaryItems --exclude=/.DocumentRevisions-V100 \
    <original>/ /Volumes/<Name>/
  ```
- Run two streams in parallel: the code folder in one, everything else in the other. Sync the bun cache
  (`~/.bun/install/cache`) separately, into `/Volumes/Repo/.cache/bun`.
- **Speed depends on file count, not size.** Large files went at 250–290 MB/s. The code folder (8.7 million small
  files, mostly `node_modules`) averaged about 29 MB/s and took almost 2 hours.

### 3. Verify the copy

Read-only on both sides:
1. Unmount the whole container (`diskutil unmountDisk`). This empties the Mac's cache of those files, so the
   later reads come from the SSD.
2. Run `diskutil verifyVolume <container>` while it is unmounted. This checks the file system's structures
   only: APFS does not checksum file contents.
3. Remount, then run `rsync -c -n --itemize-changes` with the same options. It reads every file in full on both
   sides. Sort each itemized line:
   - **suspect:** a regular file with the same modification time but a different checksum or size. Expected:
     zero. Recopy any suspect file and check it again.
   - **changed since the copy:** everything else. This is normal; the final sync takes care of it.

**Running simulators write files in place without changing their date** (SQLite `-shm`, Spotlight data). Shut the
simulators down, and sync Developer with `-c`.

### 4. Swap prep

- Move what must stay internal to `~/Local`, leave links at the old paths, and repoint every link to it.
- Back up `.zshrc` and any LaunchAgent plist before editing them.
- **Install only the helper scripts now**, after editing their setup block (section 8):
  - `mkdir -p ~/Local/bin ~/Local/ssd`
  - `install -m 755 helpers/ssd-resume helpers/ssd-off ~/Local/bin/`
  - `install -m 644 helpers/ssd-volumes.sh ~/Local/bin/`
  - `install -m 644 helpers/ssd.zsh ~/Local/ssd/`

  Add the hook line to `~/.zshrc` (section 8). Don't run `scripts/install.sh` yet: it also starts the app, and
  the app would raise alarms and try to "fix" volumes that are still at `/Volumes/<Name>` during the swap.
  **Install the app after the swap** (step 6).
- **Load the zsh hook into the shells that are already open.** `.zshrc` only reaches new shells. For each idle
  zsh pane, send `source ~/Local/ssd/ssd.zsh`, only when its input line is empty (with tmux: `tmux send-keys -t
  <pane> 'source ~/Local/ssd/ssd.zsh' Enter`). Then check it in that shell:
  `print -l $precmd_functions | grep -x _ssd_reenter_cwd`.
- Add the agent rule (section 9).

### 5. The swap

The swap is one root script, run by the **user**, per folder. Folders can be swapped in stages.

**Before the script runs:**
- **User** makes sure no agent session is in the middle of a task (they stay open), and quits Xcode, Simulator,
  Android Studio and VS Code.
- Stop the background jobs that hold files in the folder.
- Quit any app that keeps writing into the folder. On the source Mac, a session-tracking app rewrote a file in
  `~/Repo` every few seconds, so the zero-difference check never passed until it was quit.

**The script starts with `cd /`**, so it holds none of the folders open. **For each folder, it refuses to start
unless:**
- the original is a real folder, not a symlink
- `<path>.ssd-old` does not exist (otherwise `mv` would move the original *into* it)
- the volume with the expected UUID is mounted at `/Volumes/<Name>`
- no blocking app runs
- no process has a file open inside the folder

  Processes whose only tie to the folder is their **working folder** (idle shells, agent sessions) don't block
  and stay open. `lsof` reports those with the type `cwd`; leave them out of this check.

**Then, in order:**
1. **Final sync:** `rsync … --delete`, with `-c` for Developer. It must succeed: exit 0. Exit 24 ("some files
   vanished") is acceptable only for files a program deleted during the sync. Anything else stops the swap. Keep
   rsync's exit status and its error output when it runs in a pipe or in parallel (`set -o pipefail`, or write to
   files and check `$?`), and read the error output.
   - For Repo, add `--exclude=/.cache`. The bun cache exists only on the SSD, under `.cache`. Excluding just
     `/.cache/bun` still fails with "cannot delete non-empty directory: .cache". If the original folder has its
     own `.cache` content, sync that separately first.
   - Check the destination's UUID again after the sync.
2. **Zero differences:** a dry run with `--delete --itemize-changes` must exit 0 and list nothing. Its error
   output must be empty too: an empty list from an rsync that failed to read proves nothing. Ignore only the volume
   root line, and rsync's "skipping non-regular file" note about sockets (it prints that on stdout).
3. Rename the original aside to `<path>.ssd-old`.
4. **Lock the mount point:** create the empty folder at the path, `chown root:wheel`, `chmod 555`.
5. Append to `/etc/fstab`: `UUID=<uuid> <path> apfs rw,nobrowse`. Write a space in the path as `\040`.
6. Unmount the volume from `/Volumes/<Name>`, then run a plain `diskutil mount <device>`, which follows the fstab
   line.
   - **A volume can refuse to unmount right after heavy writes** ("dissented by … fseventsd"). Retry for up to a
     minute. The source Mac's first Repo swap rolled back on this; the second attempt retried and worked.
7. **Check before deleting anything:**
   - the device with the expected UUID is mounted at the path
   - the owner and mode are right
   - the top-level entry count is at least the original's
   - as the user: a test file can be created and deleted
   - git works in a few repos
   - links that point into the folder (or out of it, such as the dotfiles link left in `~/Repo`) resolve
8. **Code folder only: a late-change pass.** Copy anything written to the original between step 2 and the rename,
   then compare again; it must show zero differences.
9. **Only then, delete the original.** Run it in the background for the big folders; it takes 10–20 minutes.

**Rollback.** Any failure in steps 3–7 restores the original:
1. unmount the volume
2. remove its fstab line
3. remove the empty mount point
4. move `<path>.ssd-old` back
5. mount the volume again at `/Volumes/<Name>`

**A failure in step 8 is different.** The source script stopped with the SSD mounted at the path and the original
kept at `<path>.ssd-old`. Recover from that state by hand: finish the copy and compare again, or roll back as
above. A new script should roll back there too.

**After the swap:**
- **Agent sessions follow by themselves.** Tested with `claude -p` and `codex exec`: their folder was replaced by
  a new folder at the same path between two commands, and the next command ran in, and wrote to, the new folder.
- **Long-running helper processes** that an agent session started earlier (MCP servers, REPL helpers, Codex
  helpers) keep the old, deleted folder as their working folder. On the source Mac they were left running. If one
  misbehaves, restart its session. Tell the user this before the swap: it is the one exception to "sessions don't
  need to restart".
- **Plain zsh shells** with the hook loaded re-enter their folder on the next prompt. Send `cd -- "$PWD"` to the
  idle ones without it. After the code folder's swap, send `source ~/Local/ssd/ssd.zsh` once more to the idle
  shells: the bun cache setting is made when the file is loaded, and the cache folder exists only now.
- **Background jobs started earlier** (dev servers, daemons, emulators) keep the old folder. Restart them.
- **GUI apps:** reopen them; in VS Code, use Reload Window.

### 6. Verify, then install the app

- Every path is on the SSD (`mount`, `df`), and `/etc/fstab` has one line per volume.
- `~/Local/bin/ssd-resume --check` passes.
- git works in a few repos, and so do a package install, Xcode/`simctl`, the emulator and a Gradle build.
- Record the free space.
- Then run `scripts/install.sh`: it builds and starts SSD Monitor (section 7).

## 7. SSD Monitor (this repo)

**Repo:** https://github.com/nuynait/ssd-monitor. Clone it, or fork it if the user wants their own changes in git.

A macOS menu bar app that watches the SSD's volumes. It raises an alarm the moment one has a problem, and guides
the recovery after the SSD is plugged back in. It never touches the SSD itself: every disk action is a step of the
helper scripts (section 8).

### What it does

| State | Menu bar | On screen |
|---|---|---|
| Healthy: every volume mounted at its path, writable | drive icon | nothing |
| A problem that lasts 3 s (volume missing, at the wrong path, read-only, or the SSD gone) | red drive, also after Dismiss | Full-screen overlay on the main display, above every window. The alarm sound plays 3 times. Buttons: **Remount** (only when a volume is unmounted or at the wrong path), **Unmount the rest**, **Dismiss**. When the whole SSD is gone ("SSD disconnected"), only **Dismiss**: the resume starts by itself when it is back. |
| SSD away on purpose (`ssd-off`, or the menu's eject) | busy drive while the unmount and eject commands run; a drive with a minus while volumes are unmounted but the SSD is still attached; red drive once it is unplugged | nothing |
| SSD back, or a problem fixed | busy drive | **Resume** with a progress bar. Can't be dismissed; it ends within each step's time limit. |
| Resume finished | drive icon | Green check, and what is left to do (apps to reopen, jobs to restart). Click to dismiss. A new problem replaces it. |

The red icon has one exception: during the first 20 s after the app starts, while macOS may still be attaching
the SSD at login, an unplugged SSD shows as "waiting".

**The menu** lists, in order:
- the SSD's free space (green, yellow under 200 GB, red under 100 GB)
- each volume's state
- show the alert
- run resume now
- safely eject
- the alarm sound (any macOS alert sound, or none)
- launch at login
- the log
- quit

**Remount** mounts the missing volumes with a plain `diskutil mount`, which follows `/etc/fstab` and needs no
password. A volume mounted somewhere else is moved only if a plain unmount works; nothing is forced. If every
volume is then in place and writable, the resume runs and its result says "Remount worked". If not, the alarm
says why.

**Unmount the rest** tries a plain unmount first. If something holds the SSD, or the unmount hangs, it shows:
- diskutil's reason, which names the program that refused
- your programs with files there: program, pid, and working folder or open file
- **Try again** and a destructive **Force unmount**

Then it ejects the SSD, and shows "Safe to unplug" only once the mount table confirms nothing of the SSD is
mounted.

**Dismiss** silences this problem. The alarm comes back only if it gets worse (another volume, or the SSD gone).
When the volumes are back, the resume still runs.

**Resume** runs six steps:
1. Wait for the volumes. macOS mounts them from fstab; after 30 s the app mounts any still missing.
2. Restart the services that held files on the volumes that went away (section 8).
3. Remove stale git lock files under `SSD_REPO_ROOT`.
4. Check that all volumes are in place and `SSD_REPO_ROOT` takes a new file.
5. List apps to reopen and programs still running in SSD folders.
6. Remember the connection.

**When a step fails** or runs over its time limit, the resume stops with **Resume again** (continues from that
step), **Start over**, and **Dismiss**. If volumes are still missing after Dismiss, the resume runs by itself
once they are back.
- **Missing volumes come back while the failure screen is up:** the resume starts over by itself, with their
  services too.
- **The whole SSD went away at any point:** the resume restarts every service.
- **A volume drops out during the resume for 3 s or more:** the resume starts over with that volume's services
  too.
- **The SSD drops out during the resume:** the resume stops, and starts over once the SSD is back.
- **At most 3 automatic starts in a row**, without one finishing or the user pressing a button. Then it stops at
  the failure screen, so a loose cable can't keep the overlay up or keep bringing it back.
- **A macOS password dialog** makes the overlay step aside. The wait for the volumes and the running command's
  time limit pause until the dialog closes (other timers, such as the 3 s check, keep running).
- **A command that can't be stopped** (stuck on a dead disk) is given up on a few seconds after its limit, so no
  screen waits for it.

**Planned unplug.** This is the app's own eject, or `ssd-off` in a terminal, which leaves the marker
`~/Local/ssd/planned-unplug`:
- `ssd-off` removes the marker if it stops before the eject, and the app sees that at once.
- The marker counts while it is less than 10 minutes old. With an `ejected` line (written after a successful
  eject), it counts for as long as the SSD stays away.
- If the SSD goes away in that time, or is already away when the app starts, the unplug is confirmed: no alarm
  until the SSD is back.
- An older marker is a leftover and is ignored.
- While `ssd-off` gets ready to unplug, no resume starts, and a running one stops. If `ssd-off` stops halfway, the
  resume runs then.

**Quitting** while a command runs stops that command, and everything it started, first. SIGTERM counts as a
normal quit. Each command's temp files live in a folder of its own, removed when it ends.

### Built to cost nothing while healthy

It runs all day, so the healthy state has to be free:
- **No timers while healthy.** Two event sources:
  - DiskArbitration reports disk changes
  - a kqueue on `EVFILT_FS` reports every mount, unmount and in-place change, such as a switch to read-only

  Both are quiet: measured 2 events for one unmount and mount, none otherwise. A vnode watch on `~/Local/ssd`
  notices `ssd-off`'s marker.

  Timers run only during an incident:
  - the 3 s check
  - the grace periods (20 s after launch, 10 s after a wake), on a monotonic clock
  - a running step's time limit
  - the once-a-second password-dialog check while a command or the resume runs
- **The health check reads the kernel's cached mount table**: `getfsstat` with `MNT_NOWAIT` (one call for the
  count, one for the entries). It can't block even on a dying disk. Free space comes from the same call, when the menu opens.
- **The app never touches the SSD itself.** Mounting, the write check, `lsof` and the rest run as script steps
  with time limits, only for a button or a resume. No processes run while healthy.
- **AppKit only:** no SwiftUI, web views or third-party code.
  - The menu is built when opened, the sound list only when its submenu opens, and both are emptied a second
    after the menu closes.
  - The icon image is made only when its state changes.
  - The overlay exists only while shown.
- **Disk events are filtered at the source.** DiskArbitration reports description changes of the mount path
  only, and the health check turns only the SSD's mount-table entries into strings.
- **App Nap stays on while healthy.** It is held off only while a problem is being timed or a screen is up. Only
  a running resume or unmount also holds off idle sleep; screens waiting for the user don't.
- **Logs only state changes.**

Measured on the source Mac, healthy, over 60 s: **0.0% CPU, 0 wake-ups, 14 MB.**

### Build, install, files

- **Needs:**
  - macOS 14 or later
  - Apple silicon
  - a Swift 6 toolchain (Xcode or the Command Line Tools)
  - the helper scripts in `~/Local/bin`, carrying the line `ssd-monitor-protocol: 1`. The app runs no older
    scripts, which would run their whole routine instead.
- `scripts/install.sh`:
  - checks the helpers
  - installs them into `~/Local/bin` and `~/Local/ssd`
  - builds `build/SSD Monitor.app` (release, ad-hoc signed)
  - quits the running app (SIGTERM; it stops here if the app doesn't quit within 10 s)
  - copies the app to `/Applications` and starts it

  The app lives on the internal disk, so it runs while the SSD is gone. Launch at login is turned on at first
  start.
- `scripts/build.sh` only builds.
- Log: `~/Library/Logs/SSD Monitor/ssd-monitor.log` (state changes and every screen shown).

| Path | What |
|---|---|
| `Sources/SSDMonitor/AppController.swift` | The state machine: debounce, grace periods, alarm, remount, unmount/eject, resume, the icon state |
| `Sources/SSDMonitor/DiskWatcher.swift` | DiskArbitration and kernel mount events; the health check |
| `Sources/SSDMonitor/ResumeRunner.swift` | The six resume steps, their time limits, continue and start over |
| `Sources/SSDMonitor/Job.swift` | Running a script step with a pausable time limit; password-dialog detection |
| `Sources/SSDMonitor/Overlay.swift` | The full-screen overlay |
| `Sources/SSDMonitor/StatusMenu.swift` | Menu bar icon and menu |
| `Sources/SSDMonitor/Preferences.swift` | Alarm sound, launch at login |
| `Sources/SSDMonitor/Support.swift` | Volume list, paths, script protocol check, log |
| `helpers/` | The scripts the app runs, and the Mac's setup (`ssd-volumes.sh`) |
| `scripts/install.sh`, `scripts/build.sh` | Install everything / build the app |

The app has no paths of its own except `~/Local/bin` (the scripts) and `~/Local/ssd` (the planned-unplug
marker). It reads the volume list from `ssd-resume --step list`.

## 8. The helper scripts (`helpers/`)

| File | Installed to | What |
|---|---|---|
| `ssd-resume` | `~/Local/bin/` | After the SSD is back: puts every volume at its path, checks writes, restarts services that held files on it, removes stale git locks, lists what to reopen |
| `ssd-off` | `~/Local/bin/` | Before a planned unplug: stops what holds the SSD, unmounts, ejects |
| `ssd-volumes.sh` | `~/Local/bin/` | **The Mac's setup** (the block at the top), and helpers shared by both scripts. Sourced, not run. |
| `ssd.zsh` | `~/Local/ssd/` | zsh hook: puts `~/Local/bin` on `PATH`, re-enters the current folder after a remount, sets the bun cache |

They must live on the internal disk, never on the SSD: they are what you need while it is gone. They are written
for macOS's `/bin/bash` 3.2 (no bash 4 features). The zsh hook is loaded by the last line of `~/.zshrc`:

```zsh
[[ -r ~/Local/ssd/ssd.zsh ]] && source ~/Local/ssd/ssd.zsh
```

### Setting them up for a Mac

Edit the block between `===== This Mac's setup` and `===== End of this Mac's setup` in `ssd-volumes.sh`:

| Setting | What to put there |
|---|---|
| `SSD_VOLUMES` | One line per SSD volume: `name\|APFS volume UUID\|mount path`, where the path is the volume's `/etc/fstab` path. UUID: `diskutil info <mount path> \| grep 'Volume UUID'`. |
| `SSD_USB_NAME` | The enclosure's USB device name in the IORegistry. Find it with `ioreg -r -c IOUSBHostDevice -d 1 \| grep '<class IOUSBHostDevice'` while the SSD is plugged in (the source Mac's is `RTL9220`). Its id changes on every reconnect, which is how `ssd-resume` tells a replug from a second run. |
| `SSD_SIM_VOLUMES`, `SSD_ADB_VOLUMES`, `SSD_GRADLE_VOLUMES` | Bash arrays: which volumes each service keeps files on, e.g. `(Gradle Repo)`; quote a name with a space. The service restarts when one of them went away. An empty list `()` means none of its files are on the SSD, so it never restarts. A service that isn't running is skipped. |
| `SSD_REPO_ROOT` | The folder whose git repos get their stale locks removed, and where the write check runs; usually the code folder. The environment can override it (for tests on a scratch folder). |
| `SSD_STATE_DIR` | Where `ssd-resume` remembers the last connection and `ssd-off` leaves its marker. Keep `~/Local/ssd`: the app reads the marker there. |

Then check, changing nothing:

```bash
helpers/ssd-resume --step list     # one VOLUME line per volume
helpers/ssd-resume --check         # report only: every volume at its path
helpers/ssd-off --check            # report only: what would stop, what uses the SSD
```

**Other things that are the source Mac's, and may need editing:**
- **Services** (`step_services` in `ssd-resume`, and the shutdown part of `ssd-off`): the iOS simulator service,
  the adb server (at `~/Library/Android/sdk/platform-tools/adb`), and Gradle/Kotlin daemons. Add the Mac's own
  long-running services whose files are on the SSD, following the same pattern: stop them, then each must be gone
  within 30 s.
- **Apps to reopen** (`step_report` in `ssd-resume`): Xcode, Simulator, Android Studio, VS Code.
- **Apps that make `ssd-off` refuse** (unsaved work): Xcode, Simulator, Android Studio.
- **The bun cache line** in `ssd.zsh`: drop it if the Mac doesn't use bun, or point it at the code volume.

**Test fix-mode changes on a scratch folder only:** `SSD_REPO_ROOT=/scratch/folder helpers/ssd-resume --step
locks`. On the source Mac, a test over the real code folder removed a real stale `index.lock`. It was harmless
that time, but don't repeat it.

### `ssd-resume`

`ssd-resume --check` only reports and changes nothing. A plain `ssd-resume` does, in order:
1. **Volumes.**
   - A volume that is not mounted is mounted with a plain `diskutil mount <device>`, which follows `/etc/fstab`
     and needs no password.
   - A volume that macOS mounted somewhere else (e.g. `/Volumes/Repo 1`) is moved only if a plain unmount works;
     nothing is forced.
   - Only if that fails, and only in a terminal, it uses `diskutil mount -mountPoint`, which asks for a password.
   - A volume mounted read-only is reported.
2. **Write check** in `SSD_REPO_ROOT`. If it fails, the run stops here.
3. **Services** that held files on the SSD are restarted, only after a reconnect:
   - the simulator service
   - adb
   - Gradle/Kotlin daemons (stopped; they start fresh on the next build)

   Only this user's processes. Each must be gone within 30 s of SIGTERM (the simulator service once took about
   10 s), or the step fails; nothing is force-killed.
4. **Stale git lock files** in every repo under `SSD_REPO_ROOT`, at any depth.
   - **Where:** build and dependency folders are skipped; linked worktrees, shared common folders and submodules
     are included.
   - **Which locks:** git's own only.
     - capitalised root refs (`ORIG_HEAD.lock`, `CHERRY_PICK_HEAD.lock`, …)
     - `index`, `config`, `packed-refs`, `shallow`
     - anything under `refs/`, `logs/`, `info/`, `sequencer/`, `rebase-*`, `rr-cache/`, `objects/info|pack/`

     Other tools' locks in `.git` (such as a `gh-stack.lock`) are left alone.
   - **When a lock is removed:** only if it is older than the step, no git command runs, no program has it open
     (checked by inode), and it is still the same file right before the delete.
   - One run at a time. A search that could not read everything fails the step.
5. **Report**, after a reconnect and with `--check`: apps to reopen, and long-running programs whose folder is
   on the SSD. Shells, agents and short-lived commands such as `git` are left out.
6. **Record** the connection in `SSD_STATE_DIR/last-connection`. In a terminal run, it also clears the
   planned-unplug marker. Any failure above makes the run exit 1 and skips the record.

### `ssd-off`

`ssd-off --check` only reports. If Xcode, Simulator or Android Studio is open, `ssd-off` refuses, since they may
have unsaved work. Otherwise it lists what has files open on the SSD and asks before stopping anything. Then it:
- **writes the planned-unplug marker** `~/Local/ssd/planned-unplug`, and stops if it can't, so SSD Monitor raises
  no alarm
  - if the run stops before the eject, it removes the marker again
  - after a successful eject, the marker gets an `ejected` line, which keeps it valid however long the SSD is
    away
- shuts down simulators, emulators, adb and the Gradle/Kotlin daemons
- flushes pending writes (`sync`; a forced unmount does not flush)
- force-unmounts the whole container, because shells and agents keep their working folder there
- ejects the disk

Agents and shells can stay open; they show errors until the SSD is back.

### Step modes (for the app)

`--step NAME` prints one tab-separated line per result (`OK`, `FAILED`, `WARN`, …); exit 1 means the step failed.
- `ssd-resume --step list|mounts|services|locks|writable|report|record [--volumes A,B]`
- `ssd-off --step unmount|users|force|eject|mark`

### The zsh hook

`ssd.zsh` adds a `precmd`/`preexec` hook, `[[ . -ef $PWD ]] || cd -q -- "$PWD"`. A shell whose folder was
remounted re-enters it before its next prompt and its next command. Without it, a shell started before an unplug
stays attached to the vanished folder (`ls .` fails) until you `cd`.

## 9. The agent rule (Claude Code and Codex)

Put the same section in `~/.claude/CLAUDE.md` (Claude Code) and `~/.codex/AGENTS.md` (Codex). Both are on the
internal disk, so the rule works while the SSD is away. Replace the paths with the Mac's:

```markdown
# External SSD

`~/Repo`, `~/Downloads`, … are volumes on an external SSD, mounted at those paths. Doc: <path of the setup
README on the internal disk>.

## If the SSD gets disconnected

The SSD can come unplugged in the middle of a task. Those paths then become empty, locked folders on the Mac's
own disk, and everything under them fails. This is expected. It is not a bug to diagnose.

Signs: `No such file or directory` for files that existed moments ago, or `not a git repository`; `Permission
denied` when creating anything under those paths; the working folder gone (`getcwd` errors); `ls ~/Repo` empty.

Confirm with one command: `cd ~ && mount | grep -q " on $HOME/Repo " && echo "SSD mounted" || echo "SSD unplugged"`.

**Then stop and ask the user to plug it back in.** Say: "The external SSD looks unplugged. Plug it back in
(directly into the Mac, not a hub), wait for SSD Monitor's green check, then tell me to continue." Ask once, and
wait.

Don't work around it or try to fix it: no `mkdir`, `chmod`, `chown`, `sudo`, `diskutil` or `/etc/fstab` changes
on those paths; no re-cloning or reinstalling; no copying the work elsewhere to carry on; no deleting lock files,
killing processes or "repairing" git; no investigating disks or permissions.

After the user says it is back:
1. Make sure the recovery finished: SSD Monitor showed its green check ("SSD is back"). If it showed a failure,
   or the app isn't running, ask the user to run `ssd-resume` in a terminal; it must end without errors.
2. `ssd-resume --check` should show every volume ✓.
3. Run `cd -- "$PWD"` if the shell lost its folder.
4. Check whether the step that failed left something half-done (a git operation, a partly written file).
5. Rerun that step and continue.
```

**Tested on the source Mac:** a fresh `claude -p` and a fresh `codex exec`, given only the error messages, both
answered "the external SSD looks unplugged" and asked for the replug. Sessions that are already running pick the
rule up when they restart.

## 10. What was tested, and what is still open

| Test | Result on the source Mac |
|---|---|
| Write into an empty mount point while unplugged (disk image) | Succeeded, onto the internal disk. Fixed by the root `555` mount point: `Permission denied`. |
| Mount over a `555` mount point | Works |
| A running process reading by absolute path, after a replug | Works again |
| A running shell whose folder is on the SSD, after a replug | Broken until `cd -- "$PWD"`; the zsh hook does it by itself |
| Claude Code / Codex sessions after their folder is replaced | Follow by themselves |
| Short sleep with the SSD attached | No eject warning, mounts unchanged |
| **Real cable pull and replug** | Alarm within 3 s. On replug, **macOS mounted all volumes at their fstab paths by itself**. The app's resume started at once, restarted the simulator service, cleared git locks and finished within a minute. |
| Planned unplug (menu eject, with a forced unmount because shells were open), then replug | No alarm while away; resume by itself on replug |
| A volume unmounted by hand, then Remount or mounted again by hand | Resume by itself, green check |

**A real cable-pull test, done safely:**
1. Make sure nothing is writing: no builds, package installs or git operations, and agent sessions idle.
2. Pull the cable.
3. Check that:
   - the alarm comes up
   - the mount points are the locked placeholders (`ls -ld <path>`: root, `555`, empty)
   - a write there fails
   - agents stop and ask for the replug
4. Replug. Check that:
   - the resume finishes with the green check
   - the services it restarted are listed
   - macOS reported no disk repair: `/usr/bin/log show --last 30m --predicate 'process == "fsck_apfs"'` (a
     terminal `ssd-resume` runs this check too)
   - the same shells and agent sessions continue

**Still open** on the source Mac (checked as they happen in normal use, not with dedicated tests):
- a reboot with the SSD plugged in: all volumes should mount from fstab before apps open them
- a login without the SSD: the paths should be empty, locked folders, and no app should create files there
- a full night of sleep with the SSD attached
- a volume that macOS mounted at the wrong path (e.g. `/Volumes/Gradle 1`). The app and `ssd-resume` move it
  only if a plain unmount works; if a program holds it, quit that program and retry (Remount, or `ssd-resume`).
  If, after the unmount, a plain mount still doesn't follow fstab, only `ssd-resume` in a terminal goes on, with
  `-mountPoint` and a password dialog. It couldn't be staged without that dialog.

## 11. Gotchas learned

- **`diskutil mount -mountPoint <path>` without sudo opens a password dialog**, and a script or agent waits on it
  forever. A plain `diskutil mount <device>` follows the fstab line and needs no password, even onto a root `555`
  folder. Use the plain form.
- **Use volume UUIDs** in fstab and scripts. Disk IDs change between replugs.
- **The simulator service comes back by itself.** launchd relaunches `CoreSimulatorService` seconds after it is
  stopped. Booted simulators (`launchd_sim`) are what really block a swap: run `xcrun simctl shutdown all`.
- **The simulator service can take about 10 s to exit after SIGTERM.** Wait up to 30 s before calling it stuck.
- **Some apps ignore AppleScript `quit`:**
  - Android Studio (and once Xcode): clicking the app's own Quit menu item through System Events worked.
  - VS Code ignored both. `kill -TERM` on its main process closed it cleanly, and hot exit kept the unsaved
    files.
- **Low memory eats disk** through swap files (section 2).
- **Git-lock cleanup must match git's own lock names only.** A broad `*.lock` match would have deleted another
  tool's lock file in `.git` (`gh-stack.lock`). Remove a lock only if it is older than the cleanup, no git process
  runs, no process has it open (by inode), and it is still the same file right before the delete.
- **macOS `/bin/bash` is 3.2.**
  - `xargs` exits 1, not 123, when the utility fails.
  - `lsof` exits 1 both for "nothing open" and for errors.
  - Agent shells are often zsh, where a variable named `path` overwrites `PATH`; run loops as bash scripts.
  - In zsh, `cmd 2>&1 >/dev/null | …` still sends stdout down the pipe.
- **The SSD's temperature can't be read on macOS** through a USB bridge like the RTL9220. `smartctl` can't pass
  commands through it without a third-party kernel extension. A failing or overheating SSD shows up as a
  disconnect, which SSD Monitor catches.
- **Files that differ only in creation date** (rsync's `.f......n..`) are fixed by `-N` on the next sync. Don't
  count them as real differences.

## 12. Suggested order for a new Mac

1. Survey (section 5) and the disk-space plan (section 2). Present both to the user.
2. Backup.
3. SSD setup and the sleep test.
4. First copy, then verify it.
5. Swap prep: move what stays internal to `~/Local`, install the helpers and the zsh hook, add the agent rule.
6. Swap: small folders first, the code folder last.
7. Verify, then install SSD Monitor.
8. A real unplug and replug with the user (section 10).
9. Keep the record (README and status table) current, with a copy on the internal disk.

## 13. Working on this repo

- **Efficiency comes first.** Nothing may run while the SSD is healthy: no timers, no polling, no child
  processes. A change for efficiency must not break a working feature; test it against the existing behavior,
  including the failure cases.
- **Builds have 0 warnings.** Swift 6 toolchain, Swift 5 language mode, AppKit only, `@MainActor` classes.
- **Shell scripts** target `/bin/bash` 3.2 with `set -u`. Use `${a[@]+"${a[@]}"}` for arrays that may be empty,
  and no bash 4 features.
- **Keep the protocol line in sync.** If the step-mode output changes in a way the app depends on, change
  `ssd-monitor-protocol` in both scripts, in the app (`Paths.speaksProtocol`) and in `scripts/install.sh`.
- **After a change**, run `scripts/install.sh` and check the app's log. For behavior changes, unmount one
  unused volume by hand (for example MobileSync, if nothing uses it): you should see the alarm, the resume and
  the green check.
