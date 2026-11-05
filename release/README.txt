================================================================================
  DEAD RISING DELUXE REMASTER VR  (experimental, unfinished)
================================================================================

WHAT YOU NEED

  - Dead Rising Deluxe Remaster (Steam, PC).
  - A PC VR headset and an OpenXR runtime (tested: Meta Quest 3 with
    Virtual Desktop's VDXR runtime). Set the runtime you use as the active
    OpenXR runtime.
  - praydog's REFramework with its VR files. It is NOT included here.
    Get it from praydog's official releases:
      https://github.com/praydog/REFramework-nightly/releases
        REFramework.zip  (contains dinput8.dll)
        VR.zip           (contains openxr_loader.dll and reframework\ files)
    If a nightly does not work with this game, the stable v1.5.8 build for it
    is DD2.zip from https://github.com/praydog/REFramework/releases

INSTALLING

  1. Close the game.

  2. Find your Dead Rising Deluxe Remaster folder. In Steam, right click the
     game, then Manage, then Browse local files. DRDR.exe is in there.

  3. Install REFramework: extract dinput8.dll from REFramework.zip, and
     everything from VR.zip, into that folder next to DRDR.exe.

  4. Delete openvr_api.dll from that folder. This mod was only tested on the
     OpenXR path.

  5. Copy drdr_firstperson.lua (from the src folder) into
         <game folder>\reframework\autorun\

  6. Start your VR runtime, then start the game normally from Steam.

USING IT

  Insert   opens the REFramework menu. This mod's options are under
           Script Generated UI -> DRDR First Person VR
           (eye position, near clip, motion controls, arm settings,
           swing to attack, controller input).

  First person turns on in gameplay and steps aside during cutscenes and
  scripted cameras. Motion controls are on by default and are unfinished;
  if they get in the way, untick "Motion controls enabled" and
  "Inject controller input" in the menu. Settings are not saved between
  sessions.

UNINSTALLING

  Delete reframework\autorun\drdr_firstperson.lua to remove this mod.
  To remove REFramework too, delete dinput8.dll (and the reframework folder
  and openxr_loader.dll if you want).

THIRD-PARTY

  REFramework is by praydog, MIT License. It is not distributed with this mod.
