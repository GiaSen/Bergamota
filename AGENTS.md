# Working on Bergamota for the Xiaomi Mi 8 (dipper)

Branch `dipper` on GiaSen/Bergamota, a fork of Bergamota (Poco F1), itself a fork of ios-sweet.

## Before you start

- Read `NOTES.md`: the goal, the Mi 8's hardware facts, the STATE line (where things stand and
  the next action) and one bullet per piece of work. Work from before the Mi 8 port is in
  `docs/NOTES-before-mi8.md` (archive, not updated).

## Commits

- Subject line: 72 characters at most, `area: what changed`, e.g.
  `xnu 3127: rebuild the station vdev after a link loss` or `NOTES: camera summary`.
- A body only when it adds something the diff and NOTES do not: a few lines wrapped at 72.
  Measurements, test logs and reasoning belong in NOTES, not in commit messages.
- Never quote the user or record their approvals in commits.
- No `Co-Authored-By` or any other trailer (the dipa-studio rule in
  `docs/NOTES-before-mi8.md` is upstream ios-sweet's). Credit upstream in README.md only.
- Commit completed changes. Push only when the user asks.

## NOTES.md and README.md

- The user switches agents often. After each milestone and before stopping, rewrite the STATE
  line with the current state: the phone (what it runs), the default image, unfinished work,
  the next action. Replace it; do not keep older states in it.
- One bullet per piece of work: what was done, how, exact results (commits, image names,
  numbers) and what is still open. Say which results were observed and which are guesses.
  Update a topic's bullet instead of adding a new one for every step, and condense a finished
  topic into one bullet. Do not quote the user; write "approved by the user" only where an
  approval was needed (flashing, deleting, a new default image).
- After each milestone also update README.md: the "Status (Mi 8, DATE)" table and its date, and
  "Building for the Mi 8" if a command changed. Only claims NOTES.md or the user backs; "not
  tried" over guesses.

## Builds

- Build kernels on this Mac with `tools/xnu-local-build.sh` (from scratch about 28 minutes,
  `--remake` 18 s; the KERNEL BUILDS bullet in NOTES.md). Never start `xnu.yml` runs on
  GitHub Actions without asking: GitHub complained about the computing time.

## The phone

- Boot test images with `fastboot boot` (RAM only). Flashing anything needs the user's explicit OK.
- The iOS root lives in the `userdata` partition (the user approved using internal UFS for iOS and
  losing Android's data; no GPT changes). Android comes back from `backup/dipper` (boot.img and
  the userdata image). Keep bootloaders, recovery, modem, persist and the backups intact, and
  confirm each destructive step with the user before running it.
- Warn the user before a test that can hang the phone: they must be near to hold the power button.
  Never restart backboardd by hand; reboot instead.
- Do not run downloaded third-party scripts.

## Never in git (code, NOTES, README, commits)

- Device dumps, serial numbers, vendor data and downloaded Apple artifacts.
- Names of nearby Wi-Fi networks and Bluetooth devices, MAC and Bluetooth addresses, the LAN
  addresses of the phone and the Mac, SIM, carrier and roaming details. Read addresses at run
  time; logs that contain them stay in gitignored files.
- Photos and screenshots that show the user's home (send them to the user instead), and the
  brands or models of the user's own accessories.
