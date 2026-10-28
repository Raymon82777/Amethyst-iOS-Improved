# SDL3 Gamepad Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bundle an iOS build of SDL3 so Controlify loads it, and have the launcher's built-in controller mapping step aside while SDL owns the controller.

**Architecture:** A new `dep_sdl` Makefile target cross-compiles SDL3 (git submodule) into `libSDL3.dylib`, which the existing `payload` step copies into `Frameworks/` and signs. `JavaLauncher.m` points Controlify's FFM bindings at that file with `-Ddev.isxander.sdl.library`. `ControllerInput` polls `SDL_WasInit(SDL_INIT_GAMEPAD)` once a second from its display-link `tick` and suppresses its own handlers while SDL is active.

**Tech Stack:** GNU Make, CMake, SDL 3.4.12, Objective-C (UIKit, GameController), `dlfcn`.

**Spec:** `docs/superpowers/specs/2026-10-28-sdl3-gamepad-design.md`

## Global Constraints

- SDL source: submodule `Natives/external/SDL`, URL `https://github.com/libsdl-org/SDL`, tag `release-3.4.12`.
- SDL CMake: `-DCMAKE_SYSTEM_NAME=iOS`, `-DCMAKE_OSX_ARCHITECTURES=arm64`, `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`, `-DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_FRAMEWORK=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_AUDIO=OFF`, built `--config RelWithDebInfo`.
- Bundled file name and location: `<bundle>/Frameworks/libSDL3.dylib` (exactly one copy, not a symlink).
- JVM property: `-Ddev.isxander.sdl.library=<bundle>/Frameworks/libSDL3.dylib`, added only if the file exists.
- `SDL_INIT_GAMEPAD` = `0x2000`. SDL state is checked at most once per second.
- Building and testing need macOS (Xcode, iphoneos SDK) and an iOS device with a Bluetooth controller. The repo has no automated test harness for `Natives/`; verification is build output, `otool`/`nm`, and on-device checks.
- Target mod: latest Controlify (Java 22+, FFM bindings `controlify-sdl`). Older JNA-based Controlify is out of scope.

## Review Focus

1. **A button or stick held at the moment SDL takes over** — the key must be released, not left stuck down (covered in Task 3, step 5 check b).
2. **Controlify not installed** — the built-in mapping must behave exactly as before; `libSDL3.dylib` is never loaded, so detection must stay inactive (Task 3, check d).
3. **SDL loaded but `SDL_Init` failed** — Controlify falls back to GLFW; the launcher must keep its mapping on because `SDL_WasInit` returns 0 (Task 3, check e).
4. **Build without the SDL dylib present** (e.g. `dep_sdl` skipped) — the launcher must not pass a path to a missing file (Task 2, step 3).
5. **Controller connected after the game starts, or reconnected mid-game** — handover state must apply to callbacks registered later too (Task 3, check f).

---

### Task 1: Build and bundle libSDL3.dylib

**Files:**
- Create: `Natives/external/SDL` (git submodule), entry in `.gitmodules`
- Modify: `Makefile` — new `dep_sdl` target after `dep_mg` (~line 326); `payload` prerequisites (line 342); `help` text if it lists targets (~line 234)

**Interfaces:**
- Produces: `$(WORKINGDIR)/libSDL3.dylib` (real file), copied by `payload`'s existing `cp $(WORKINGDIR)/*.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/` into `AngelAuraAmethyst.app/Frameworks/libSDL3.dylib`. Exports `SDL_WasInit`, `SDL_Init`, `SDL_GetVersion`.

- [ ] **Step 1: Add the submodule**

```bash
git submodule add https://github.com/libsdl-org/SDL Natives/external/SDL
git -C Natives/external/SDL checkout release-3.4.12
```

- [ ] **Step 2: Add the `dep_sdl` target**

Model it on `dep_mg`: echo start/end lines in the same `[Amethyst v$(VERSION)] dep_sdl - start` format, `mkdir -p $(WORKINGDIR)/sdl`, configure with `cmake` using the Global Constraints flags plus `-DCMAKE_OSX_SYSROOT="$(SDKPATH)"`, source dir `$(SOURCEDIR)/Natives/external/SDL`, then `cmake --build $(WORKINGDIR)/sdl --config RelWithDebInfo -j$(JOBS)`. Copy with `cp -L $(WORKINGDIR)/sdl/libSDL3.dylib $(WORKINGDIR)/libSDL3.dylib` (`-L` dereferences the `libSDL3.dylib -> libSDL3.0.dylib` symlink). Add `dep_sdl` to the `.PHONY` list if the Makefile has one.

- [ ] **Step 3: Make `payload` depend on it**

Change `payload: native dep_mg java jre assets` to `payload: native dep_mg dep_sdl java jre assets`.

- [ ] **Step 4: Build and verify the dylib (macOS)**

Run: `make dep_sdl`
Then:
- `otool -l Natives/build/libSDL3.dylib | grep -A4 LC_BUILD_VERSION` → `platform 2` (iOS), `minos 14.0`
- `lipo -info Natives/build/libSDL3.dylib` → `arm64` only
- `nm -gU Natives/build/libSDL3.dylib | grep -E " _SDL_(WasInit|Init|GetVersion)$"` → all three
- `otool -L Natives/build/libSDL3.dylib` → lists `GameController.framework`; no `AudioToolbox`/`AVFAudio`
- `ls -l Natives/build/libSDL3*.dylib` → `libSDL3.dylib` is a regular file and is the only `libSDL3*` file in `Natives/build/`

- [ ] **Step 5: Verify bundling**

Run: `make payload` (or full `make`), then `ls -l Natives/build/AngelAuraAmethyst.app/Frameworks/libSDL3*` → exactly one regular file `libSDL3.dylib`. After `make package`, `codesign -dv` (or `ldid -e`) on that file inside the IPA shows it is signed like its neighbours.

- [ ] **Step 6: Commit**

```bash
git add .gitmodules Natives/external/SDL Makefile
git commit -m "build: bundle SDL3 for iOS as libSDL3.dylib"
```

---

### Task 2: Point Controlify's SDL bindings at the bundled library

**Files:**
- Modify: `Natives/JavaLauncher.m:241` (after the `-Djava.library.path` line)

**Interfaces:**
- Consumes: `<bundle>/Frameworks/libSDL3.dylib` from Task 1.
- Produces: JVM system property `dev.isxander.sdl.library`, read by `controlify-sdl`'s `SdlNativeLibrary.configure()`.

- [ ] **Step 1: Add the property**

After the `java.library.path` line, build `NSString *sdlPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];` and, only if `[NSFileManager.defaultManager fileExistsAtPath:sdlPath]`, append `-Ddev.isxander.sdl.library=<sdlPath>` to `margv` using the same `[NSString stringWithFormat:...].UTF8String` idiom as the surrounding lines. Log it with `NSLog(@"[JavaLauncher] SDL3 library: %@", sdlPath);`; when missing, log `NSLog(@"[JavaLauncher] SDL3 library not bundled, skipping");`.

- [ ] **Step 2: Verify with SDL bundled (device)**

Build, install, launch any instance. Expected in the launcher log: `[JavaLauncher] SDL3 library: .../Frameworks/libSDL3.dylib`. Launch an instance with the latest Controlify. Expected in `latestlog.txt`: `Loaded SDL from system` followed by `Successfully initialised SDL subsystems`. A warning that SDL's audio subsystem failed to initialise is expected and fine.

- [ ] **Step 3: Verify without SDL bundled**

Delete `Natives/build/AngelAuraAmethyst.app/Frameworks/libSDL3.dylib`, repackage, launch. Expected: `SDL3 library not bundled, skipping`; game launches normally. Restore the file afterwards.

- [ ] **Step 4: Commit**

```bash
git add Natives/JavaLauncher.m
git commit -m "feat: point SDL3 bindings at bundled libSDL3.dylib"
```

**If step 2 fails**, record the exact error. "Could not load SDL natives" or an `UnsatisfiedLinkError`/FFM exception means spec risk 1 (FFM on iOS Java 25). An `SDL_Init` error means spec risk 3. Stop and report before Task 3.

---

### Task 3: Hand the controller over to SDL

**Files:**
- Modify: `Natives/input/ControllerInput.m` (all changes are file-private; `ControllerInput.h` is unchanged)

**Interfaces:**
- Consumes: `libSDL3.dylib` at `<bundle>/Frameworks/libSDL3.dylib`, loaded by the JVM (Task 2); its `SDL_InitFlags SDL_WasInit(SDL_InitFlags flags)`, where `SDL_InitFlags` is `Uint32`; call it through `uint32_t (*)(uint32_t)`.
- Produces (file-private, main thread only):
  - `static BOOL sdlActive;`
  - `+ (void)updateSDLState` — throttled check, at most once per second; on change sets `sdlActive` and on `NO → YES` calls `releaseHeldInputs`.
  - `+ (void)releaseHeldInputs` — releases everything the launcher holds.
  - `static NSMutableSet<NSNumber *> *heldKeys;` — GLFW keycodes currently pressed via `sendKeyEvent:` / the left-stick WASD path.
  - `static char lastLThumbDirection` — hoisted from the left-thumbstick block to file scope so it can be reset.

- [ ] **Step 1: Track held keys**

In `sendKeyEvent:pressed:` and the WASD block, add the keycode to `heldKeys` on press and remove it on release for every `CallbackBridge_nativeSendKey` call. Track mouse buttons sent via `CallbackBridge_nativeSendMouseButton` the same way, in a separate `static NSMutableSet<NSNumber *> *heldMouseButtons`. Hoist `lastLThumbDirection` (initial value `-2`) to file scope.

- [ ] **Step 2: Implement `updateSDLState`**

```objc
+ (void)updateSDLState {
    static CFTimeInterval lastCheck;
    static uint32_t (*wasInit)(uint32_t);
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastCheck < 1.0) return;
    lastCheck = now;

    if (!wasInit) {
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) return;
        wasInit = dlsym(handle, "SDL_WasInit");
        if (!wasInit) return;
    }

    BOOL active = wasInit(0x2000 /* SDL_INIT_GAMEPAD */) != 0;
    if (active == sdlActive) return;
    sdlActive = active;
    NSLog(@"[ControllerInput] SDL gamepad subsystem %@, built-in mapping %@", active ? @"active" : @"inactive", active ? @"disabled" : @"enabled");
    if (active) [self releaseHeldInputs];
}
```

(`RTLD_NOLOAD` means this never loads SDL itself. The handle is deliberately not `dlclose`d, so SDL stays loaded until the JVM unloads it.)

- [ ] **Step 3: Implement `releaseHeldInputs`**

Call `CallbackBridge_nativeSendKey(key, 0, 0, 0)` for every keycode in `heldKeys` and `CallbackBridge_nativeSendMouseButton(button, 0, 0)` for every button in `heldMouseButtons`, then empty both sets. Call `CallbackBridge_*` directly, not `sendKeyEvent:`: `sdlActive` is already `YES` here, so `sendKeyEvent:` would return early. The left-shift toggle's press is in `heldKeys` because step 1 tracks every `nativeSendKey` call. If `leftShiftHeld`, set it to `NO` (its key is already in `heldKeys`). Set `lastXValue = lastYValue = 0` and `lastLThumbDirection = -2`. Before emptying the sets, log `NSLog(@"[ControllerInput] Released %lu keys, %lu mouse buttons", heldKeys.count, heldMouseButtons.count);`.

- [ ] **Step 4: Gate input on `sdlActive`**

- At the top of `+tick`, call `[self updateSDLState]`; if `sdlActive`, set `lastFrameTime = 0` and return before sending mouse movement. Resetting `lastFrameTime` avoids a large delta on resume.
- At the top of `sendKeyEvent:pressed:`, return if `sdlActive`. Every button handler routes through it.
- At the top of the left- and right-thumbstick `valueChangedHandler` blocks, return if `sdlActive`.
- Add `#include <dlfcn.h>` to the imports.

- [ ] **Step 5: Build and verify on device**

Run: `make native` (macOS), then package and install. Check:
- a. **Controlify + Bluetooth controller (Xbox or DualSense):** the log shows `[ControllerInput] SDL gamepad subsystem active, built-in mapping disabled` within about a second of the title screen. In-game, the left stick moves the player once, not twice. The right stick turns the camera only through Controlify, with no extra virtual-mouse drift. A press gives one action.
- b. **Handover with input held:** with Controlify installed, launch the game. During loading, before the "active" log line, the built-in mapping is still live. Hold a button mapped in the gamepad map's menu list (e.g. one mapped to left mouse or a key) and hold the left stick. Keep holding until the "active" line appears, then let go. Join a world: no key or mouse button is stuck down and the player doesn't move on their own. The log shows `[ControllerInput] Released N keys, M mouse buttons` with N + M ≥ 1.
- c. **Rumble:** trigger a Controlify rumble (e.g. take damage) on a controller that supports it on iOS. The controller vibrates.
- d. **No Controlify:** the "SDL gamepad subsystem" log line never appears; the built-in mapping works as before (stick = WASD, buttons per the gamepad map, virtual mouse in menus).
- e. **SDL init fails:** temporarily replace `Frameworks/libSDL3.dylib` with a copy built with `-DSDL_JOYSTICK=OFF`, or accept Task 2's failure case if it reproduced. Controlify falls back to GLFW; the "active" line never appears; the built-in mapping still works.
- f. **Reconnect:** with Controlify active, turn the controller off and on mid-game. Controlify re-detects it; the built-in mapping stays suppressed (the launcher re-registers callbacks on connect, and they still return early).

- [ ] **Step 6: Commit**

```bash
git add Natives/input/ControllerInput.m
git commit -m "feat: hand controller input to SDL3 when a mod initialises it"
```

**If check a shows Controlify detects no controller**, that is spec risk 2 (SDL's iOS backend off the main thread). Record what SDL logs (`SDL_GetError`, Controlify's controller list) and report. Do not work around it inside this task.
