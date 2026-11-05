# Dead Rising Deluxe Remaster VR

An unfinished first person VR mod for Dead Rising Deluxe Remaster (Steam, RE Engine). It is a
Lua script for praydog's [REFramework](https://github.com/praydog/REFramework), which already
gives RE Engine games stereo rendering and 6DOF head tracking over OpenXR. On this game
REFramework falls back to its generic third person VR. This script moves the game's own camera
into Frank's head, so the game plays in first person, and adds work-in-progress motion controls.

There is no compiled code and no injector of its own: REFramework (`dinput8.dll`) is the
injection method, and this project is the script it loads from `reframework/autorun/`.

⚠️ Experimental, **unfinished** community mod. Not affiliated with Capcom, and not part of
REFramework. Use at your own risk. Development has stopped, and the source is published so that
others can pick it up. See [What doesn't work yet](#what-doesnt-work-yet) and
[`docs/TECHNICAL_NOTES.md`](docs/TECHNICAL_NOTES.md).

Licensed under [GPL-3.0](LICENSE).

## What it does

Confirmed in headset testing on a Meta Quest 3 over Virtual Desktop's OpenXR runtime (VDXR),
OpenXR only, with REFramework nightly-01395:

- **Stereo and 6DOF head tracking.** Provided by stock REFramework; this script does not change
  it.
- **First person camera.** Each frame the game camera is moved to Frank's `C_Head` joint, nudged
  forward and up to eye level, and REFramework's head tracking is composed on top. Eye offsets
  are adjustable live.
- **No head in the way.** The camera near clip is raised (0.15 m by default) so Frank's own head
  is clipped away, wherever its meshes live. The original near clip is restored whenever first
  person disengages, including when the headset is inactive.
- **Cutscenes and scripted cameras are left alone.** When the game hands the camera to a
  scripted controller the script steps aside, and takes over again in gameplay.
- **Settings menu.** Insert opens the REFramework menu; the script's options are under
  *Script Generated UI* → *DRDR First Person VR*.

## What doesn't work yet

- **Motion controls are on by default, and are work in progress.** They run in the headset
  but are not finished:
  - The held weapon follows the right hand, and both arms are posed by a two-bone IK solve from
    the controller poses. Arms still **cross over the chest** when walking backwards or
    sideways, because the game turns Frank toward his movement direction while the view stays
    put, and arms **do not always reach full extension**.
  - Pinning Frank's body to the camera heading fixes the crossing in principle, but made the
    character spin and blocked forward movement. It is **off by default** (damped, with a
    deadzone, toggle in the menu). The script logs the angle between Frank's forward and the
    camera heading once per session; if that reads near 180° while walking forward, the
    character's forward sign is the bug.
  - **Quest controller input** is injected as gamepad input. The left stick (head relative,
    "move where you look") worked in testing. The fix that routes the buttons through
    REFramework's joystick action handles is the newest input change and is not confirmed.
  - **Swing to attack:** a fast right controller swing presses the game's attack button, and the
    arm IK hands the bones back to the animation while the attack plays. Whether swings reliably
    register hits is **unknown**. There is no physical melee: a weapon passing through a zombie
    does nothing by itself, because the game's attack animation carries the hitbox.
  - If motion controls interfere, untick *Motion controls enabled* (arms and weapon) and
    *Inject controller input* in the menu.
- **No per-mesh head hiding.** The near clip does the job, but it can also clip walls you stand
  very close to. `app.solid.PlayerCostumeChanger` is the likely route to hiding the head meshes
  properly. The *Hide head mesh* option finds nothing on Frank today.
- **Settings are not saved.** Menu changes last for the session only; defaults are in the
  `cfg` table at the top of the script.
- **Only tested on one setup.** Quest 3, VDXR, OpenXR. SteamVR / OpenVR is untested. The game
  is not on REFramework's official supported list (it uses the Dragon's Dogma 2 build), so a
  future REFramework or game update can break it.
- **Diagnostic logging is still in.** The script logs its discovery dumps (input devices, a
  nearby zombie's damage-related methods, arm telemetry) to REFramework's log.

## Building

Nothing to compile. See [BUILD.md](BUILD.md) for how to check the scripts.

## Installing

See [`release/README.txt`](release/README.txt). In short: install REFramework with its VR files
from praydog's official releases, delete `openvr_api.dll`, and copy `src/drdr_firstperson.lua`
into `reframework/autorun/`.

REFramework itself is **not** included in this repo. Get it from praydog:

- Nightly builds: https://github.com/praydog/REFramework-nightly/releases
  (`REFramework.zip` for `dinput8.dll`, `VR.zip` for the VR files and `openxr_loader.dll`)
- Stable releases: https://github.com/praydog/REFramework/releases (this game uses `DD2.zip`
  from v1.5.8)

## Layout

| Path | What's there |
|---|---|
| `src/` | `drdr_firstperson.lua`, the mod: first person camera, near clip, cutscene detection, motion controls, input injection, settings UI |
| `tools/` | `drdr_probe.lua`, the read-only discovery probe used to find the game's camera and player types. Not needed to play |
| `docs/` | `TECHNICAL_NOTES.md`: architecture, the game types and fields used, approaches that failed and why, where to go next |
| `release/` | End-user install notes |
| `third_party/reframework/` | REFramework's MIT license, for the camera-write approach adapted from it (no REFramework code or binaries are included) |

## License

GPL-3.0 - see [LICENSE](LICENSE). Copyright (C) 2026 Halcyon.

## Credits

praydog, for REFramework and its VR support, which do all the rendering and tracking work here.
The first person camera write (full HMD pose on the camera Transform, pre-HMD position plus yaw
only on the camera joint) follows praydog's `re8_vr.lua` from REFramework, MIT License,
Copyright (c) 2019 praydog; the license text is in `third_party/reframework/LICENSE`.
