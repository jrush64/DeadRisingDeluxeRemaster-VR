# Building Dead Rising Deluxe Remaster VR

There is nothing to compile. The mod is a Lua script that REFramework loads at runtime, so
"building" means checking that the scripts parse and putting the file in the right place.

## Prerequisites

- Windows 10/11, x64, and Dead Rising Deluxe Remaster (Steam).
- praydog's REFramework with its VR files (see [`release/README.txt`](release/README.txt)).
  REFramework provides the Lua 5.4 runtime and the `sdk`, `re`, `vrmod`, `imgui` and `log`
  APIs the script uses.
- Optional, for a syntax check outside the game: any Lua 5.4 `luac`.

## Checking the scripts

```
luac -p src\drdr_firstperson.lua tools\drdr_probe.lua
```

No output means both parse. The scripts cannot run outside the game: every call goes through
REFramework's API.

## Deploying

Copy `src\drdr_firstperson.lua` into `<Dead Rising Deluxe Remaster install>\reframework\autorun\`
while the game is closed. REFramework loads it at startup (or use *ScriptRunner* →
*Reset scripts* in the REFramework menu to reload it while the game is running).

The script logs to REFramework's log file in the game folder (`re2_framework_log.txt`), with
every line tagged `[DRDRFP]`. The probe tags its lines `[DRDRPROBE]`.

`tools\drdr_probe.lua` is a diagnostic. Copy it into `autorun` only when you need a fresh dump
of the game's camera and player types; it dumps three samples once you are in gameplay and
does nothing else. Remove it afterwards.

## Third-party components

| Component | Location | License |
|---|---|---|
| REFramework (not included; required at runtime) | get it from praydog's releases | MIT |
| REFramework license text, for the adapted camera-write approach | `third_party/reframework/LICENSE` | MIT |
