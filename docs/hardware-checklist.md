# Hardware checklist

What the automated tests can't cover: real Magic devices, real sleep and
wake, two physical Macs. Run through this before tagging a release. Logs
are at `~/Library/Logs/Monnect.log` on each Mac (Settings → Show Log in
Finder); every step below leaves an `EVENT` line there.

## Install

- [ ] Build on each Mac (`app/make-dmg.sh`) or install the DMG. Quit the
      old version first.
- [ ] First launch opens the setup window by itself.

## Setup

- [ ] Personal Mac: **Set Up My First Mac** → Allow Bluetooth → system
      prompt appears → device list shows the Magic Mouse and Keyboard,
      both pre-ticked.
- [ ] A code like `K7QM2-XFD9P` appears. Work Mac: **Join My Other Mac** → type the code →
      "You're All Set". Local Network prompt appears on both; allow it.
- [ ] Both menus show "<other Mac>: online" within ~15 s.
- [ ] Type a wrong code once: the joiner says it's wrong and the host keeps
      waiting. Type the right code next: it pairs.
- [ ] Manual address: on the join screen, open "Can't find your other
      Mac?" and use the address shown under the code. Works too.

## Switching

- [ ] Pull on the work Mac **without touching the devices**. Note the
      seconds in `EVENT … connected after Ns`: about 4–5 s for devices in
      use. If a device has slept, the menu asks for a tap after ~6 s.
- [ ] Pull back on the personal Mac. Same.
- [ ] Pull with one device switched **off**: the other joins; the menu
      says "Waiting for …". Turn it on: it joins without another click.
- [ ] While one Mac is waiting, pull on the other Mac: the first stops
      waiting (`other Mac asked us to release`) and doesn't take anything back.
- [ ] Menu shows each device as "here" / "on <other Mac>" correctly, and
      updates instantly when a device connects (no 5 s lag).
- [ ] `open -g monnect://pull` from Terminal switches too.

## Lid close (MacBook with the devices, other Mac awake)

- [ ] Close the lid. Log: `willSleep: lid closed, other Mac awake` then
      `released on lid close`. Pull on the other Mac: it comes over with a tap.
- [ ] Close the lid with the other Mac **asleep**: log says the other Mac is
      asleep/unreachable and keeps the devices. Reopen: the devices
      reconnect on their own, with no fresh pairing.
- [ ] Released on lid close, nobody took them, reopen: log shows the
      wake reclaim and the devices come back (a tap if they slept).
- [ ] Clamshell mode (external display, lid shut): sleep from the Apple
      menu → log says `causesSleep=false … keeping devices` → the keyboard
      wakes the Mac.
- [ ] Leave a lid closed for an hour: no `claim` lines between `willSleep`
      and `didWake` (nothing is claimed during Power Nap).

## Upgrade path (do this first if both Macs still run 0.1.x)

Note: on the personal Mac the 0.1 token was replaced during development
(2026-10-26), so these two Macs need to pair again anyway: Settings →
Pair Another Mac on one, Join on the other.

- [ ] A Mac upgraded from 0.1 still starts with its devices, and Settings
      shows the "paired by Monnect 0.1" note.

## Settings

- [ ] Change Devices on one Mac: the other Mac picks up the new list.
- [ ] Toggle "Open Monnect when I log in", log out and back in.
- [ ] Reset Monnect → setup window opens; devices stay where they were.

## What the first hardware run found (2026-10-26, macOS 26.6 + 27)

All sections above passed. Switches took 4–5 s (7 runs with a wiggle, then one hands-off run at 4.4 s: devices in use need no touch),
lid-close release took ~20 ms before sleep, clamshell mode kept the devices
and the keyboard woke the Mac. Two Bluetooth facts shaped `attemptClaim`:

- **Never open a connection to an unpaired device.** On macOS 26+,
  IOBluetooth's `openConnection` goes through bluetoothd, which then pairs
  the device itself and, because no app asked, shows the system's
  "Connection Request" dialog. `IOBluetoothDevicePair` marks the pairing as
  app-requested (`didRequestPairing … 1` in the bluetoothd log) and is
  handled silently.
- **`remoteNameRequest` never calls back** on macOS 26+ (starts with
  success, then nothing), so it can't serve as a quick "awake?" probe.
  The short answer window is done by stopping the pairing after a few
  seconds unless the link is already up.

To check for the dialog after a change:
`log show --last 2m --predicate 'process == "bluetoothd"' | grep -E "BluetoothUIServer|handled the pairingRequested"`
should list only `handled the pairingRequested` lines.
