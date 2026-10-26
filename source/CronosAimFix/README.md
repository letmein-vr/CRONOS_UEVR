# CronosAimFix: UEVR weapon aim plugin for Cronos: The New Dawn

Makes the player's shots come out of the motion-controller-held gun barrel instead of the camera.
Built on praydog's SH2R UEVR plugin template.

## What the plugin hooks

The player's guns fire through `TraceShotFromScreen` on the weapon mode's trace component. The plugin resolves the
real native function from each class's Blueprint thunk (the `mov rsi, [rax+disp]` vtable slot read from the class
default object) and inline-hooks it. Subclasses that have their own vtable need their own hook, even when they don't
override the function:

| Class | Weapons |
|---|---|
| `BTWeaponModeTraceComponent` | Handgun (GravityGun), AutoGun, HeavyRifle, Rerouter |
| `BTSpreadGunTraceComponent` | Shotgun (SpreadGun), DoubleBarrell |
| `BTSmartGunTraceComponent` | SmartGun (machine gun) |
| `BTAnnihilatorTraceComponent` | Annihilator (Arbalest) |
| `BTEnergyEmitterTraceComponent` | EnergyEmitter |
| `BTFlamethrowerTraceComponent` | Flamethrower |
| `BTWeaponModeProjectileTraceComponent` | Projectile modes |
| `CronosWeaponFireComponent` | Grenade base |

## What it changes

* **Start and direction.** Start = the weapon's `MuzzlePoint` world location, direction = the gun root's forward
  vector rotated 90° about its up vector (the barrel axis), 8192 cm long. `GunAdjustV` / `GunAdjustH` from the config
  file nudge the end point. Projectile modes start at the right `MotionControllerComponent` and follow its forward vector.
* **The player is ignored.** The game only leaves the player out of its weapon traces while the gun is attached under
  the pawn. In VR the gun hangs off the motion controller, and shotgun pellet traces start 200 cm behind the shot
  origin (`ConeShootStartLocationOffset = -200`), so the shot would hit the player's own capsule. The local pawn is
  appended to `ActorsToIgnore` in place. The game resizes and frees that array itself, so it is grown with the game's
  own `FMalloc` (never a buffer from the plugin's allocator, which crashes `FMallocBinned2`).

Trap mines are not handled here: their arc is computed natively from the game's aim rotation, not from a trace.
`scripts/roomscale_turn.lua` aims that rotation along the right controller while `IsInTrapMineAim` is true.

`MuzzlePoint` is left on the pistol's `GG_muzzle` socket by the game; `scripts/hands.lua` re-snaps it to each gun's own
`*_muzzle` socket (for example `SprdG_muzzle`) whenever the gun mesh changes.

`CronosStereoManager` / `CronosTickManager` are compiled in, but their callbacks are no-ops: the Lua profile already
handles the spotlight, two-handing, the flashlight toggle and visibility, and running both makes them fight.

## Config: `<profile>\plugins\Cronos.txt` (optional)

`GunAdjustV=<cm>` and `GunAdjustH=<cm>`. A file named `debug` in the profile folder opens a console with trace logging.

## Build

1. Put [glm](https://github.com/g-truc/glm) in `dependencies\glm` (the original project has it as a git submodule).
2. Run `_build.bat` (VS 2026). bddisasm, spdlog and kananlib are fetched by CMake.
3. Copy `build\Release\CronosAimFix.dll` to the profile's `plugins\` folder and fully restart the game.
