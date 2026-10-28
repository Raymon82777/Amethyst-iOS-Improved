# SDL3 gamepad support for mods (Controlify)

Date: 2026-10-28
Status: Approved design, pending implementation plan

## Goal

Let mods that use SDL3 for controller input — primarily the latest Controlify
(Java 22+, FFM-based SDL bindings) — work with Bluetooth controllers on iOS,
including SDL-only features (rumble, gyro, touchpad) where iOS exposes them.

Out of scope: older Controlify builds that use libsdl4j over JNA, and
implementing the GLFW gamepad API (`glfwGetGamepadState` etc. in
`JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java`). Both are possible follow-ups.

## How Controlify finds SDL

Controlify's `SDLNativesLoader` tries, in order: a `controlify_natives` mod,
LWJGL's SDL (inactive), natives inside the Controlify jar, then the "system"
library. It already knows an `IOS` platform (`ios-aarch64` resource prefix),
but no iOS natives are published, so on iOS only the system path can succeed.

The system path is `SdlFfmLoader.create()` → `SdlNativeLibrary.configure()`
from `controlify-sdl` (bindings `release-3.4.14-7`, natives `release-3.4.12`):

- If `-Ddev.isxander.sdl.library=<path>` is set, it binds that file via
  `SymbolLookup.libraryLookup(path)`.
- Otherwise it calls `System.loadLibrary("SDL3")`, which searches
  `java.library.path` — already set to `<bundle>/Frameworks` in
  `Natives/JavaLauncher.m`.

So a correctly built and signed `libSDL3.dylib` in the app's `Frameworks/`
folder is all Controlify needs. No mod changes, no Java-side patches.

## Design

### 1. Build SDL3 for iOS

- Add SDL as a git submodule at `Natives/external/SDL`
  (`https://github.com/libsdl-org/SDL`), checked out at the release tag
  Controlify ships as `sdl_natives` (currently `release-3.4.12`), so iOS runs
  the same SDL version Controlify is tested with on other platforms.
- Add a `dep_sdl` Makefile target, modelled on `dep_mg`, that configures SDL
  with CMake into `$(WORKINGDIR)/sdl`:
  - `-DCMAKE_SYSTEM_NAME=iOS` (not `Darwin`, unlike `dep_mg`: SDL selects its
    UIKit / GameController backends from the iOS system name),
    `-DCMAKE_OSX_SYSROOT="$(SDKPATH)"`, `-DCMAKE_OSX_ARCHITECTURES=arm64`,
    `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`.
  - `-DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_FRAMEWORK=OFF -DSDL_TEST_LIBRARY=OFF`.
  - `-DSDL_AUDIO=OFF`: Controlify also calls `SDL_InitSubSystem(SDL_INIT_AUDIO)`;
    on iOS that would configure `AVAudioSession` and could fight the game's
    OpenAL audio. With audio compiled out the call fails and Controlify logs a
    warning and continues.
  - Build with `--config RelWithDebInfo`, then copy the real (non-symlink)
    library to `$(WORKINGDIR)/libSDL3.dylib`, so the existing
    `cp $(WORKINGDIR)/*.dylib .../Frameworks/` line in `payload` picks it up
    exactly once.
- Add `dep_sdl` to the prerequisites of `payload` (it doesn't depend on
  `native`, and nothing in `native` links against SDL).
- Signing needs no change: everything in `Frameworks/` is already signed with
  the app.

### 2. Point the bindings at the bundled library

In `Natives/JavaLauncher.m`, next to `-Djava.library.path`, add:

```
-Ddev.isxander.sdl.library=<bundle>/Frameworks/libSDL3.dylib
```

This makes loading independent of library-path search order. Only add it if
the file exists, so a build without SDL behaves exactly as today.

### 3. Hand the controller over to SDL automatically

The launcher's `ControllerInput` maps controller buttons to keys/mouse. If
SDL is also reading the controller, every input would act twice. The
launcher therefore steps aside while an SDL user is active.

- Detection, in `ControllerInput`, called from the existing `+tick`
  (driven by the `CADisplayLink` in `SurfaceViewController`), throttled to
  once per second:
  - `dlopen("<bundle>/Frameworks/libSDL3.dylib", RTLD_LAZY | RTLD_NOLOAD)`;
    if it is loaded, cache the handle and `dlsym` `SDL_WasInit`.
  - SDL is "active" when `SDL_WasInit(SDL_INIT_GAMEPAD)` (`0x2000`) is
    non-zero. `SDL_WasInit` only reads subsystem ref-counts, so calling it
    from the main thread is safe.
- While active:
  - Every button and thumbstick handler set in
    `registerControllerCallbacks:` returns early.
  - `+tick` stops sending virtual-mouse movement.
- On the transition to active, release anything the launcher is currently
  holding (W/A/S/D, left shift toggle, mouse buttons) so no key stays stuck.
- If SDL is later shut down (`SDL_WasInit` returns 0), the built-in mapping
  resumes.
- Handlers stay registered throughout; SDL reads `GCController` state on its
  own and is unaffected by the launcher's per-element handlers.

### 4. Failure behaviour

If SDL fails to load or initialise, Controlify falls back to its GLFW driver
by itself. `SDL_WasInit` never reports the gamepad subsystem, so the
launcher's built-in mapping stays on. Worst case is today's behaviour.

## Risks to check during implementation

1. **FFM on iOS Java 25.** Controlify's bindings use FFM downcalls. Confirm the
   bundled Java 25 runtime supports them on iOS arm64 (JIT enabled).
2. **SDL's iOS joystick backend off the main thread.** Controlify calls
   `SDL_Init` and polls events from the game thread. SDL's MFi/GameController
   code registers `NSNotificationCenter` observers and reads `GCController`
   state; confirm connect/disconnect and input work from that thread.
3. **SDL build on iOS without SDL owning the app.** The launcher, not SDL,
   owns `UIApplication`. Joystick, gamepad and events subsystems should not
   need SDL's app delegate; verify `SDL_Init` succeeds.

## Testing

These need a macOS build host and a device with a Bluetooth controller.

1. Build with `make`; confirm `Frameworks/libSDL3.dylib` is in the `.app` and
   signed.
2. Launch a modern MC instance with Controlify. The log shows
   "Loaded SDL from system" and "Successfully initialised SDL subsystems".
3. Connect a Bluetooth controller (Xbox, DualSense). Controlify detects it;
   buttons, sticks and triggers work in menus and in-game.
4. Inputs don't fire twice: no WASD movement or virtual-mouse motion from the
   launcher while Controlify is active.
5. Rumble works on a controller that supports it on iOS.
6. Without Controlify, the built-in controller mapping still works as before.
7. Connect and disconnect the controller mid-game; no stuck keys, no crash.
