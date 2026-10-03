> **Spider-Man stuck inside a building?** Just tell your AI agent to teleport you 200 m into the air.
>
> *For the agent:* write the line `hero tp 0 200 0` to `logs\sm_cmd.txt` (meters relative to Spider-Man; the second number is up). The guest DLL runs it within half a second and logs `teleport ... held` to `logs\sm_guest.log`.

# ArkWeb

https://www.youtube.com/watch?v=O6Mkm_NGCX8

Spider-Man's web swinging in Batman: Arkham Knight's Gotham.

ArkWeb runs **Marvel's Spider-Man Remastered** alongside **Batman: Arkham Knight**. You play Spider-Man's
own movement (swinging, wall running, wall crawling, point launches) with a controller, or keyboard and
mouse, while looking at Arkham Knight. Gotham's collision is streamed into Spider-Man's physics world, so he
swings off and runs on Gotham's buildings. His own rendered frame is cut out and drawn into Arkham's view in
Batman's place.

The architecture follows [SkyCraft](https://github.com/chasmlol/SkyCraft): a hidden guest game drives the
moveset, and the host game shows it.

**Status: experimental.** It works end to end but is a research project with rough edges. See the
known issues below.

## How it works

| Part | What it does |
|---|---|
| `src/sm_guest/` → `winmm.dll` in Spider-Man | Publishes the hero and camera, plays a virtual controller, lets the mouse turn Spider-Man's camera, fakes window focus, and builds Gotham's collision (Havok compressed meshes) about 2 km above New York so New York's own ledges are out of reach. It also patches the hero's transition manager for zip-to-point and perching, and captures Spider-Man's frame (D3D12) for the host. |
| `src/ak_host/` → `dinput8.dll` in Arkham Knight | Drives Batman as a hidden puppet at Spider-Man's position, mimics Spider-Man's camera, and draws the captured frame (D3D11). It also scans Gotham with the game's own traces and exports its PhysX statics and grapple points. |
| `protocol/`, `src/common/` | Shared-memory link (`Local\ArkWeb_v1`): seqlock state slots, rings and coordinate conversion (UE3 Z-up cm ↔ Spider-Man Y-up m) |
| `tools/gotham_stream.py` | The streamer. It follows the hero, asks Arkham for tile scans (50 m tiles) and PhysX exports, builds collision tiles and swing hints, and sends them to Spider-Man. |
| `tools/` (others) | Reverse-engineering helpers (PE, RTTI, strings, disassembly, xrefs), offline fakes of either game, debugging viewers |

Zip to point uses Arkham's grapple points as targets (L2 + R2, with a marker drawn in Arkham's view). With
nothing pressed, Spider-Man perches on the point. A jumps or launches off; B drops.

### Combat

When Arkham says Batman is fighting (its own `IsInCombat` check), the mod hands the fight to Arkham Knight
automatically, and hands it back two seconds after the fight ends:

- Arkham plays Batman with its own freeflow combat, controller and combat camera. Batman stays hidden.
- Spider-Man is pinned to Batman's position and takes Batman's pose every frame. His joints are turned to match
  Batman's skeleton: hips, spine, shoulders, arms, legs and feet, scaled to his proportions.
- Spider-Man's camera copies Arkham's, so the captured Spider-Man lines up with Arkham's picture.

Spider-Man's joint hierarchy isn't stored anywhere the mod could find, so it was worked out from recorded motion
(`tools/sm_pose_sampler.py`, `tools/sm_skel_probe.py`, `tools/ak_skel_probe.py`). `tools/retarget_v2.py` is the
same pose transfer in Python, for checking it offline.

## Requirements

- Windows 10 x64 and a PC that can run both games at once
- **Marvel's Spider-Man Remastered v4.0630** (Steam). Everything is bound to that build's addresses; other
  builds refuse to hook.
- **Batman: Arkham Knight** (Steam)
- An Xbox-style controller, or a keyboard and mouse
- Python 3.12 with `numpy`, `scipy`, `numba`, `pefile` and `capstone` (for the streamer and tools). `play.bat`
  installs the packages, and Python itself with winget if you say so.
- Only to build the DLLs yourself: Visual Studio 2019 or later (the Build Tools are enough) with the x64 C++ tools
  and a Windows SDK (for `fxc`). Without it the DLLs come from `prebuilt\`.

## Install

1. Get this repository onto your PC: clone it, or Code → Download ZIP and unpack it anywhere.
2. Close both games and double-click `install.bat`. It finds both games in your Steam libraries (or asks for the
   folder), puts the DLLs next to them and points their logs at this folder's `logs\`, where the streamer works too.
   Games in Program Files need administrator rights: Windows asks. A `dinput8.dll` or `winmm.dll` of another mod is
   kept aside, and `uninstall.bat` puts it back when it takes ArkWeb out.

`play.bat` does this step by itself when the games don't have this version yet.

The DLLs come from `bin\` when you build them yourself with `build.bat` (both DLLs and the tests, at low priority
on one core) and they are newer, else from `prebuilt\`, which GitHub Actions builds from this source
(`.github/workflows/build.yml`).

`arkweb.ini` next to either DLL can override `[ArkWeb] LogDir=` and a few switches (see `PHASE1.md`).
Logs go to `logs\`.

>Pro Tip: Just tell your AI agent to do it for you

## Playing

1. Double-click `play.bat`. It installs ArkWeb if needed, checks Python and the streamer's packages, starts both
   games through Steam and then the streamer (`tools\gotham_stream.py`). Keep its window open while you play.
2. Load into the open world in each game, Batman on a street. Keep Arkham Knight in front.
3. Stand still with Spider-Man for a few seconds: the streamer builds the area around you and lifts Spider-Man
   onto Gotham.
4. Play with the controller, or keyboard and mouse. `play.bat` started again mid-session resumes the streamer
   (`--resume`).

### Keyboard and mouse

With no controller connected, Arkham's keyboard drives Spider-Man while Arkham Knight is in front:

| Input | Spider-Man |
|---|---|
| W A S D | move |
| Space | jump |
| Left Shift | swing |
| Left Ctrl | dodge |
| Mouse | his camera |

The mouse turns Spider-Man's camera the way it does in Spider-Man itself (his mouse sensitivity setting
applies): the guest lets Spider-Man read the mouse in the background. Clicks and the wheel stay with Arkham.
In a fight Arkham's own camera is the view, so the mouse turns that one. Zip to point and the other buttons
need a controller. `cam mouse` in `logs\sm_cmd.txt` reports what reaches the camera. `cam mouse off` (or a
Spider-Man that can't read the mouse in the background) brings back the old way: his camera steered toward
Arkham's hidden one.

**Your Arkham Knight save follows Batman.** Arkham autosaves while Batman is the puppet, so don't leave
Spider-Man under the map. The host refuses to move Batman far below the streets, and `tp x y z` (feet, UU)
in `logs\ak_cmd.txt` moves Batman back to a safe spot.

### Live commands

Write one command per line to `logs\sm_cmd.txt` (Spider-Man) or `logs\ak_cmd.txt` (Arkham Knight). Results
go to `logs\sm_guest.log` and `logs\ak_host.log`.

| Game | Examples |
|---|---|
| Spider-Man | `hero tp 0 200 0`, `zip status`, `zip perch on\|off`, `gotham stream status`, `gotham surface <hex>`, `cap status`, `cam mouse [on\|off]` |
| Arkham Knight | `tp x y z`, `batman hide\|show\|auto`, `overlay on\|off`, `overlay gamma <g>`, `shot`, `cam mimic on\|off`, `px info` |

## Known issues

- Arkham's building collision is often hollow, and Gotham comes from vertical scans plus PhysX. Thin spires
  and very narrow buildings can still be swung through.
- Swinging very fast into a district Arkham hasn't loaded yet can leave gaps for a few seconds, until
  it loads and the tile is rescanned.
- A zip whose path is blocked is cut short and Spider-Man drops (there's no line-of-sight check yet).
- Spider-Man can look dark in places (his lighting comes from New York's time of day).
- In combat, hands and wrists aren't copied (no fists), and the camera cuts at the start and end of a fight.
- The combat pose transfer is tied to the suit it was recorded with. A suit with a different skeleton is detected
  (bone lengths are checked) and the mirror stays off.
- Do **not** run `bin\link_test.exe` while the games are running. It opens the live shared memory.

## Repository layout

| Path | Contents |
|---|---|
| `src/`, `protocol/` | The two DLLs and the shared link |
| `install.bat`, `uninstall.bat`, `play.bat` | Install into both games, take it out again, play (`tools/install.ps1`, `tools/play.ps1`) |
| `prebuilt/` | The two DLLs, built from this source by GitHub Actions |
| `tools/` | The streamer and reverse-engineering scripts (`tools/README.md`) |
| `tests/` | Offline link and motion-smoothing tests |
| `recon/PHASE0*.md`, `PHASE1.md`, `PHASE2.md` | Findings and phase notes, with addresses |
| `recon_dll/` | The passive recon probes used at the start |

Not included: `logs/`, build output, and the raw dumps of the game executables (strings, RTTI, the UE3
SDK, disassembly). The scripts in `tools/` regenerate those from your own copies of the games.

## Disclaimer

An unofficial fan project, not affiliated with Insomniac Games, Nixxes, Sony Interactive Entertainment,
Rocksteady Studios or Warner Bros. Games. It contains no game files; you need your own copies of both
games.
