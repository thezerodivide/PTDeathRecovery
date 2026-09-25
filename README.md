# PTDeathRecovery

PTDeathRecovery is a MacroQuest Lua script for Project Triune. It watches for character death, returns the character from The Bazaar to the current expedition, and verifies that Triune Auto Combat (TAC) is running before declaring recovery successful.

Current version: **v1.0.0**

## What it does

After recognizing a death, PTDeathRecovery:

1. Waits for Project Triune to return the character to The Bazaar.
2. Navigates to the Waypoint Map.
3. Opens the Waypoint Map and confirms that a current expedition is available.
4. Activates expedition travel and verifies that zoning begins and completes.
5. Waits until TAC is ready to receive commands.
6. Checks TAC's state, starts it if necessary, and independently verifies that it is running.
7. Returns to monitoring for the next death.

PTDeathRecovery observes the results of its commands rather than assuming that a command succeeded merely because it was sent.

## Requirements

- Project Triune
- MacroQuest with Lua and ImGui support
- MQ2Nav loaded, with a working Bazaar navmesh (included in releases)
- [Triune Auto Combat](https://github.com/gennro/TriuneAutocombat) V3.1 loaded and awaiting commands
- Character bind point set to The Bazaar
- A current expedition already available to join
- Waypoint Map **Auto-Confirm** enabled

PTDeathRecovery does not create or join expeditions, configure TAC, install navmeshes, select Bazaar instances, or automate the respawn window.

## Installation

### Release archive

Extract the release archive into your MacroQuest directory while preserving its folder structure.

### Manual installation

Copy `PTDR.lua` into your MacroQuest `lua` directory.

## Usage

Start PTDeathRecovery from the MacroQuest console:

```text
/lua run PTDR
```

The window should display:

```text
PTDeathRecovery v1.0.0
```

PTDeathRecovery immediately enters **Monitoring - waiting for death**. No additional command is required.

To stop it:

```text
/lua stop PTDR
```

## Controls

### Pause / Resume

**Pause** suspends recovery progress and stops navigation owned by PTDeathRecovery. Time spent paused does not count against active recovery timeouts.

**Resume** revalidates the current recovery context before continuing. If navigation was interrupted, PTDeathRecovery restarts its navigation command without spending another attempt.

The initial release does not provide special unstuck movement after the user manually relocates the character while paused. Existing navigation timeouts and retries still apply.

### Retry Count

The default Retry Count is `5`. This means five retries after the initial attempt, for up to six total attempts per retry-covered operation.

Navigation, opening the Waypoint Map, initiating expedition travel, and starting TAC each have independent retry budgets. Retry Count can be changed only while PTDeathRecovery is Monitoring.

### Verbose MQ output

When enabled, detailed diagnostic messages are also printed to the MacroQuest window. File diagnostics are always enabled regardless of this setting.

Retry Count and Verbose MQ output are saved per server and character.

## Logs and settings

PTDeathRecovery uses MacroQuest's configured directories rather than hard-coded paths.

Settings:

```text
config/PTDeathRecovery_<server>_<character>.ini
```

Diagnostic log:

```text
logs/PTDeathRecovery_<server>_<character>.log
```

Every log entry includes the running version, for example:

```text
2026-09-25 11:16:29 | INFO | build=v1.0.0 | recovery=- | state=MONITORING | Monitoring - waiting for death.
```

The diagnostic log rotates at approximately 1 MiB and retains one `.1` backup.

When reporting a failure, include the result shown in the PTDeathRecovery window and the corresponding diagnostic log.

## Common failure messages

### No interactable current expedition is available

PTDeathRecovery opened the Waypoint Map, but its current-expedition button was disabled. Confirm that the character already has an expedition available to enter.

### MQ2Nav is unavailable or the Bazaar navmesh is not loaded

Confirm that MQ2Nav is loaded and that a usable Bazaar navmesh is installed.

### Navigation attempts exhausted

PTDeathRecovery could not reach a position from which the Waypoint Map could be opened. Review the log for timeouts, path failures, or manual movement performed while recovery was paused.

### Expedition travel attempts exhausted

The expedition button was activated, but zoning did not begin within the allowed time. Confirm that the expedition remains valid and that Waypoint Map Auto-Confirm is enabled.

### TAC did not answer a status probe

Confirm that TAC V3.1 is loaded and responsive to `/ac status`.

## Scope

PTDeathRecovery is deliberately focused. It does not perform:

- Corpse recovery
- Expedition creation or selection
- Bind-point configuration
- TAC configuration
- Navmesh installation, repair, or generation
- Bazaar instance switching
- Generic travel automation
- Recovery from arbitrary environment changes made while paused

## Versioning

PTDeathRecovery follows [Semantic Versioning](https://semver.org/):

- Patch releases correct behavior without changing the intended interface.
- Minor releases add backward-compatible functionality.
- Major releases may introduce breaking changes.

The stable release filename remains `PTDR.lua`. The exact version appears in the UI and in every diagnostic log entry.
