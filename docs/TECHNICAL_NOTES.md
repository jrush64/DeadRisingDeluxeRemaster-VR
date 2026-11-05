# Technical notes

How the mod works, which game types and fields it relies on, and which approaches were tried
and failed, so whoever continues does not repeat them. Everything here was found by runtime
probing with `tools/drdr_probe.lua` and the script's own log dumps; nothing comes from the game
executable.

## Platform

- Dead Rising Deluxe Remaster is RE Engine (Capcom, 2024), Steam app 2527390, TDB version 73.
- REFramework added the game in v1.5.8 using the Dragon's Dogma 2 build (`DD2.zip`). It is not
  on REFramework's official supported-games list. Current nightlies are a single build for all
  games (`REFramework.zip` plus `VR.zip`). Tested with nightly-01395.
- `reframework:get_game_name()` returns **`drdr`**, not `dd2`. Both scripts return early on any
  other value. The RE2/RE4/RE8 VR scripts that ship in `VR.zip` guard on the game name the same
  way and do nothing here.
- REFramework's VR on this game is the "generic 6DOF" mode used for third person RE Engine
  games (DMC5, MH Rise, DD2): stereo, head tracking, gamepad input. No first person and no
  motion controls; those exist in REFramework only for RE2/3/4/7/8.
- REFramework's OpenXR action set is already bound on this game: grip pose, trigger, squeeze,
  thumbstick and click, A/X, B/Y, system and menu, for both hands. No input plumbing had to be
  built to read the controllers.

### Division of labour

| Layer | Does |
|---|---|
| REFramework C++ | stereo rendering, projection, per-eye offset, OpenXR session, controller poses |
| `drdr_firstperson.lua` | places the mono game camera at Frank's head, composes the HMD pose with `vrmod:apply_hmd_transform`, stops the game undoing it, then drives the arms, weapon and gamepad input |

Nothing in the script touches FOV or projection matrices. REFramework owns projection.

## Game types and fields

DRDR does not use the `app.PlayerCamera` style types of RE7/RE8. It has its own framework under
`app.solid.*`, so none of the type names from REFramework's RE8 VR script apply.

### Camera

All on the `MainCamera` GameObject:

| Type | Notes |
|---|---|
| `app.solid.camera.CameraManager` | singleton component. `<BusyCameraController>k__BackingField` says which controller drives the camera; `<PlayerHeadJoint>k__BackingField` populates in gameplay and names `C_Head` |
| `app.solid.camera.DefaultMainCamera` (base `app.solid.camera.MainCamera`) | `lateUpdate` is the hook seat. Fields: `<CameraJoint>k__BackingField` (the render joint), `<CameraPosition>k__BackingField`, `<CameraRotation>k__BackingField`, `<FOV>k__BackingField`, `<bUpdateCamera>k__BackingField`, `CameraShakeWorkList`, `RecoilParam`. Methods include `updateCameraShake`, `updateCameraRecoil` |
| `via.Camera` | `get_NearClipPlane` / `set_NearClipPlane` |

The camera transform has one joint, `Camera`. There is no `UpdateCamera` application entry in
this engine build.

Controller types seen in `BusyCameraController`:

- `app.solid.camera.PlayerCameraController`: normal gameplay.
- `app.solid.camera.FixedCameraController`: scripted camera or cutscene.

That one signal is the whole cutscene test. (REFramework's RE8 script needs five signals, a
hysteresis and a cutscene blacklist for the same job.) `CameraManager.PlayerManagement`
(`app.solid.PlayerManagerBridge`) is also only populated in gameplay.

### Player

- The player is the GameObject named exactly **`Pl_Frank`**, found by scanning
  `via.motion.Motion` components. **`Pl_Frank_UI`** is the inventory/menu model, parked at world
  (0, 200, 0). A substring match picks it up and puts the camera 200 m in the sky.
- Frank's rig has 210 joints with the same naming as every other character (zombies have 22):
  `root`, `COG`, `C_Spine_*`, `C_Neck`, `C_Head`, `C_Jaw`, `R/L_Shoulder`, `R/L_UpperArm`,
  `R/L_Forearm`, `R/L_Hand`, `R_Weapon` (weapon attach point), `R/L_UpperLeg`, `R/L_Foreleg`,
  `R/L_Foot`, plus finger, twist and helper joints.
- `via.Joint:get_Position` / `set_Position` are **world** space (verified by reading
  `Pl_Frank_UI`'s root at exactly (0, 200, 0), and by writing a known offset and reading it back).
- `CameraManager.<PlayerHeadJoint>` reported a position that did not match Frank, so the script
  reads `C_Head` from Frank's own transform (`getJointByName`) instead.
- Frank's transform hierarchy holds only carried items (`PREF_Item*`, `PREF_DefaultHands`,
  `Item_None_SPIT`). His body meshes are not in it. `app.solid.PlayerCostumeChanger` swaps his
  outfit meshes and its `_PartObjects` holds the body parts. Zombie mesh parts are named `Body`,
  `Head`, `Leg`, `Feet`, `ACC00`.

### Input

| Type | Notes |
|---|---|
| `via.hid.GamePad` (native singleton) / `via.hid.GamePadDevice` | engine pad; `set_AxisL/AxisR/Button/ButtonDown`, `get_Connecting` (no setter) |
| `via.hid.GamePadButton` | button enum, read from static fields at load (`RLeft`, `RDown`, `Decide`, ...) |
| `app.solid.InputSystem` (managed singleton) | game input; keeps its own `ActiveUserDevice`, active `InputUnit`, `InputMode`, `_LStick`, `_RStick`, `_ButtonBits` |
| `app.solid.InputUnit` | per-user state: `<Device>k__BackingField`, `ButtonOn/Down/Up`, sticks, `CommandBits`; methods `update`, `updateButtonBit`, `updateCommand`, `getGamePadButton`, `isOn/isDown/isUp/isRepeat(kind)` |
| `AnalogStick` | a **value type** with `Axis`, `RawAxis`, `Magnitude`, `Direction`, `Angle` (no `x`/`y`) |

## Per frame (the shipping path)

Hook: `app.solid.camera.DefaultMainCamera::lateUpdate`. The pre hook stashes `args[2]`
(`this`), because post hooks only get the return value; the post hook calls `write_camera`.

1. Bail out and restore (near clip, head mesh state) if the HMD is inactive, the script is
   disabled, `Pl_Frank` or `C_Head` is missing, or `BusyCameraController` is not the player
   controller. Restoring on every exit path matters: otherwise taking the headset off leaves
   the flat game with a clipped view.
2. Set the camera near clip to `near_clip` (0.15 m), saving the original once.
3. Read the camera Transform rotation and the `C_Head` world position. Offset the position by
   `eye_forward` (0.12), `eye_up` (0.04), `eye_right` (0) in camera space. **Forward is -Z.**
4. Clone that as the pre-HMD pose, then `vrmod:apply_hmd_transform(rot, pos)` (mutates in place).
5. Write the full HMD pose to the camera `via.Transform` (drives game logic). Write the
   **pre-HMD position and only the yaw of the HMD delta** to `<CameraJoint>` (falling back to
   `get_Joints()[0]`), which is what renders. REFramework's stereo renderer adds the full HMD
   pose on top of the joint, so giving the joint the full rotation applies pitch and roll twice.
   This split is taken from REFramework's `re8_vr.lua` (MIT, praydog).
6. Write the pre-HMD pose back into `<CameraPosition>` / `<CameraRotation>` so the game's
   camera solver does not drag the camera back next frame.
7. Derive the room-to-world transform for the controllers by inverting the HMD transform:
   `room_rot = camera_rot * inverse(hmd_rot_local)`, `room_pos = camera_pos - room_rot * hmd_pos_local`.
   This survives recentering and standing-origin changes without tracking them.
8. Compute the signed yaw between the game camera and the view (for head relative movement),
   measure Frank's heading against the camera heading (and pin it if enabled), then run the
   motion controls.

Motion controls run again at `LateUpdateBehavior`, because animation overwrites joint writes
every frame. Input injection runs at `UpdateHID` (post) and `UpdateBehavior` (pre), plus the
hooks below.

## Motion controls

### Arms (`arm_update` / `arm_solve`)

- Writes **local rotations only**, on four bones per side: `*_Shoulder` (clavicle),
  `*_UpperArm`, `*_Forearm`, `*_Hand`. Children follow through the hierarchy, so bone lengths
  cannot change and twist/helper bones are not orphaned. For bone B with parent P and a wanted
  world delta D, after the parent got D_P: `B_local_new = inv(D_P * P_world) * D * P_world * B_local`.
  Parent rotations after upstream writes are computed analytically rather than re-read.
- The minimal rotation between two directions is built by axis-angle. `Quaternion.new`'s
  argument order is undocumented, so on first use both orders are tried against a known vector
  and the working one is kept (logged).
- **Hand frame mapping, no calibration pose.** The OpenXR grip pose has -Z along the fist toward
  the thumb and +X normal to the palm. Frank's hand frame is measured once from the rig: wrist to
  knuckle centroid from the finger base joints, thumb direction from the thumb joint, palm side
  from the right hand rule, with the sign checked against the held weapon (which sits in the
  palm). `hand_world = ctrl_world * Q`. *RE-MEASURE HAND FRAMES* in the menu redoes it (after a
  costume or weapon change).
- **Wrist target.** The controller is in the player's fist, so the wrist target is the fist
  point minus the measured wrist-to-grip offset (the weapon joint when one is held).
- **Arm length matching.** The target is scaled about the shoulder by `frank_arm / player_arm`,
  so Frank's elbow bend matches the player's. One arm length is shared by both sides, seeded
  from standing eye height (about a third of stature) and raised by the largest plausible reach
  seen. Shoulder position for the player is estimated from the eyes (`arm_neck_drop` 0.22,
  `arm_neck_back` 0.04, `arm_shoulder_half` 0.18).
- **Elbow hint**: down and outward from body facing, smoothed with hysteresis.
- **Clavicle**: takes a capped share of the reach swing (35%, max 32°).
- **Weapon**: the hand-to-weapon relationship is read from the animated pose each frame before
  the arm is written, and reapplied to the new hand pose, so the game's own grip is preserved.
  When a target is out of reach the hand and weapon take the clamped position and stay attached.

### Swing to attack

In Dead Rising the attack animation carries the hitbox. Moving the weapon mesh does not hit
anything. So a right controller speed over `swing_speed` (2.2 m/s, 0.4 s cooldown) presses the
attack button for 0.1 s, and the arm weight blends to zero for `attack_hold` (0.5 s) so the
animation owns the bones while the attack plays, then blends back (`arm_blend_time` 0.12 s).

### Input injection

Controller sticks and buttons are written as gamepad input. Default mapping (`MAP` in the
script; Xbox names): right trigger → X (attack), A → A, B → B, right grip → RT, left trigger →
LB, left X → back/select, left Y → Y, left grip → LT, menu → start, stick clicks → stick clicks.
The left stick is rotated by the HMD yaw delta so forward walks where you look.

What it took to make the game read it, in order:

1. Writing `via.hid.GamePadDevice` alone is ignored: the game reads through
   `app.solid.InputSystem`, which keeps its own active device and `InputUnit`.
2. The script sets the merged device as `ActiveUserDevice`, fills the unit's device field, and
   forces `InputMode` to the pad value from the enum.
3. The unit's computed state is overwritten before and after its update, and
   `app.solid.InputUnit::update` is hooked post side so the injected values are the last word.
4. `AnalogStick` is a value type: every getter returns a copy, so mutating it does nothing. It
   has to be copied out, changed and assigned back. The script probes the possible write forms
   once against a sentinel, reads back, and keeps the one that sticks.
5. The game consumes the command layer (`isOn(kind)`, `CommandBits`), which the unit derives
   inside its update. The script re-runs `updateButtonBit` / `updateCommand` after writing, and
   hooks `isOn/isDown/isUp/isRepeat` (and `isTrigger/isRelease` on `InputSystem`) on both
   `InputUnit` and `InputSystem`, answering from the injected mask via `getGamePadButton(kind)`.
6. The whole pipeline is gated on the device reporting connected. There is no
   `set_Connecting`, so `via.hid.GamePadDevice::get_Connecting` is hooked and answers true for
   the injected device only (matched by pointer).
7. `vrmod:is_action_active` needs **action handles** from `get_left_joystick` /
   `get_right_joystick`, not the device indices from `get_controllers` (those are for poses).
   Passing device indices matches nothing and fails silently. This was the newest input fix.

## Approaches that failed, and why

- **+Z as forward.** RE Engine forward is -Z. With +Z the eye offset pushed the camera out of
  the back of the skull. At 0.10 it looked like being inside the head, at 0.20 like being behind
  it: one cause, two symptoms.
- **Hiding the head mesh.** Grouping meshes by transform parent found nothing; grouping by
  position found only `PREF_DefaultHands`; a 2.5 m sweep around `C_Head` found nothing. Frank's
  body meshes are not reachable that way. The near clip removes the head regardless.
- **Collapsing the `C_Head` joint scale.** `via.Joint` has `set_LocalScale`, not `set_Scale`, so
  the call silently did nothing. Even with the right setter, anything written into a joint must
  be rewritten every frame, because animation overwrites it. The dead `set_Scale` path is still
  in the script.
- **Driving `R_Weapon` from the controller and the arm separately.** Two paths from one source
  disagreed; the wrist wrung and the blade sat at the wrong angle. Now there is one chain:
  controller → hand → arm IK, and the weapon follows the hand.
- **Absolute weapon orientation, then a calibration delta.** Absolute needed the weapon bone's
  axis convention (unknown); a delta snapshot taken on an arbitrary animation frame baked a
  permanent offset into every frame (palm-up left hand, sideways blade). Replaced by the rig
  derived hand frame.
- **Writing world positions into arm joints, and composing two `to_quat()` results.** Positions
  stretch bones and orphan helper bones on a 210 joint rig; `to_quat` composition leaves roll
  arbitrary. Replaced by local rotations and a true minimal rotation.
- **Aiming the wrist at the controller.** The controller is in the fist, so Frank overreached,
  the arm locked straight and the elbow bend became ill defined.
- **Per-arm learned arm length.** The left arm was never extended, learned 0.42 m and went stiff
  when scaled up. One shared length now.
- **`set_field` on wrong names.** REFramework's `set_field` does not fail on an unknown field
  name, so a stick writer setting `x`/`y` reported success while doing nothing. Read back
  anything you write.
- **Filtering hook overloads by `get_params()`.** That method does not exist in this REFramework
  build; the filter matched nothing and installed zero hooks. Also, wrapping `sdk.hook` in a
  silent `pcall` hid that failure; hook failures are now logged.
- **Pinning Frank's yaw to the view.** The game camera follows the character, so turning him
  toward the view moved the view: a feedback loop that spun him endlessly and stopped forward
  movement. Pinning to the game camera heading has no such loop but still spun in testing,
  so it is off by default, damped (25% per frame) with a 12° deadzone.

## Debugging

- Log: `re2_framework_log.txt` in the game folder. Script lines start with `[DRDRFP]`.
- Useful one-off lines: `hooked app.solid.camera.DefaultMainCamera::lateUpdate`,
  `first person engaged` (with head joint and camera positions), `original near clip`,
  `motion control joints: ...`, `body vs camera heading: N deg`, `hooked app.solid.InputUnit::update
  (post) for injection`, `connecting hook target set`, query intercept install counts.
- Periodic lines report arm reach, learned arm length and extension ratio, elbow and hand
  landing error, and (with *Input debug log*) what the game side sees from the pad.
- The menu shows live status: active, in cutscene, player and head joint found, last error,
  arm status, hand speed and swing count, arm weight, pad device, HMD yaw delta.
- `damage_recon` logs a nearby zombie's components and any damage/hit/hp/attack-shaped methods
  once per session, plus any global damage or hit manager types.
- If it crashes on boot, remove `openxr_loader.dll` and check the game runs flat with only
  REFramework's `dinput8.dll`, to separate a REFramework problem from an XR runtime problem.
  Delete or rename `dinput8.dll` to return to the stock game.

## Where to go next

1. **Body vs view.** Read the logged `body vs camera heading` while walking forward. Near 180°
   means the character's forward sign differs from the camera's, which would explain the pin
   spinning. Fix that, then re-enable the pin, and the arm crossing should go with it. An
   alternative is to stop the game turning Frank toward his movement direction.
2. **Full arm extension.** Check the logged shoulder-to-wrist distance against the assumed arm
   length; the shoulder estimate decides whether the arm can straighten.
3. **Confirm button input**, then confirm swings register hits. If they do not, physical melee
   needs custom blade collision against zombies (maths over the weapon joint) and a way to tell
   the game a zombie was hit; the `damage_recon` dump is the starting point.
4. **Proper head hiding** through `PlayerCostumeChanger._PartObjects`, so the near clip can come
   back down.
5. **Camera shake and recoil** in the headset: if they bother, skip
   `DefaultMainCamera::updateCameraShake` / `updateCameraRecoil` with
   `sdk.PreHookResult.SKIP_ORIGINAL`. If the game's camera solver ever fights the override,
   `MainCamera.<bUpdateCamera>k__BackingField = false` is the next lever.
6. **Save settings** with REFramework's `json` module.
7. Strip the discovery dumps once they have served their purpose.
