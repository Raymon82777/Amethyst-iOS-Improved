#import "ControllerInput.h"
#import "../LauncherPreferences.h"
#import "../PLProfiles.h"
#import "../SurfaceViewController.h"
#import "../utils.h"

#include <dlfcn.h>

#include "../glfw_keycodes.h"

// Left thumbstick directions
#define DIRECTION_EAST 0
#define DIRECTION_NORTH_EAST 1
//#define DIRECTION_NORTH 2
#define DIRECTION_NORTH_WEST 3
//#define DIRECTION_WEST 4
#define DIRECTION_SOUTH_WEST 5
//#define DIRECTION_SOUTH 6
#define DIRECTION_SOUTH_EAST 7
#define MOUSE_MAX_ACCELERATION 2

CFAbsoluteTime lastFrameTime;
CGFloat lastXValue; // lastHorizontalValue
CGFloat lastYValue; // lastVerticalValue

// State below is main-thread only (GameController handlers and the display link both run there)
// YES once a mod (e.g. Controlify) has initialised SDL's gamepad subsystem; the built-in mapping then stands down
static BOOL sdlActive;
// GLFW keycodes / mouse buttons currently pressed by the launcher, so they can be released on handover to SDL
static NSMutableSet<NSNumber *> *heldKeys;
static NSMutableSet<NSNumber *> *heldMouseButtons;
// Last direction of the left thumbstick WASD emulation, -2 = nothing sent yet
static char lastLThumbDirection = -2;

static void sendTrackedKey(int keycode, BOOL pressed) {
    if (!heldKeys) {
        heldKeys = [NSMutableSet new];
    }
    if (pressed) {
        [heldKeys addObject:@(keycode)];
    } else {
        [heldKeys removeObject:@(keycode)];
    }
    CallbackBridge_nativeSendKey(keycode, 0, pressed, 0);
}

static void sendTrackedMouseButton(int button, BOOL pressed) {
    if (!heldMouseButtons) {
        heldMouseButtons = [NSMutableSet new];
    }
    if (pressed) {
        [heldMouseButtons addObject:@(button)];
    } else {
        [heldMouseButtons removeObject:@(button)];
    }
    CallbackBridge_nativeSendMouseButton(button, pressed, 0);
}

@implementation ControllerInput

NSMutableDictionary *gameMap, *menuMap;
BOOL leftShiftHeld;

+ (void)initKeycodeTable {
    if (gameMap && menuMap) {
        return;
    }
    
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultGamepadCtrl"];
    NSString *gamepadPath = [NSString stringWithFormat:@"%s/controlmap/gamepads/%@", getenv("AME_HOME"), controlFile];
    NSMutableDictionary *gamepadJSON = parseJSONFromFile(gamepadPath);
    
    gameMap = gamepadJSON[@"mGameMappingList"];
    menuMap = gamepadJSON[@"mMenuMappingList"];
}

/**
 * Check whether a mod has initialised SDL's gamepad subsystem, at most once per second.
 * RTLD_NOLOAD means this never loads SDL itself.
 */
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
        // The handle is deliberately not dlclose'd, so SDL stays loaded until the JVM unloads it
        wasInit = (uint32_t (*)(uint32_t))dlsym(handle, "SDL_WasInit");
        if (!wasInit) return;
    }

    BOOL active = wasInit(0x2000 /* SDL_INIT_GAMEPAD */) != 0;
    if (active == sdlActive) return;
    sdlActive = active;
    NSLog(@"[ControllerInput] SDL gamepad subsystem %@, built-in mapping %@", active ? @"active" : @"inactive", active ? @"disabled" : @"enabled");
    if (active) [self releaseHeldInputs];
}

/**
 * Release everything the launcher is holding, so nothing stays stuck once SDL takes over
 */
+ (void)releaseHeldInputs {
    // Call CallbackBridge_* directly, sdlActive is already YES so sendKeyEvent would return early
    for (NSNumber *key in heldKeys) {
        CallbackBridge_nativeSendKey(key.intValue, 0, 0, 0);
    }
    for (NSNumber *button in heldMouseButtons) {
        CallbackBridge_nativeSendMouseButton(button.intValue, 0, 0);
    }
    NSLog(@"[ControllerInput] Released %lu keys, %lu mouse buttons", heldKeys.count, heldMouseButtons.count);
    [heldKeys removeAllObjects];
    [heldMouseButtons removeAllObjects];

    // The left shift toggle's key is already released through heldKeys
    leftShiftHeld = NO;
    lastXValue = lastYValue = 0;
    lastLThumbDirection = -2;
}

+ (void)sendKeyEvent:(int)controllerKeycode pressed:(BOOL)pressed {
    if (sdlActive) return;

    int keycode = GLFW_KEY_UNKNOWN;
    __block NSMutableDictionary *mapping;
    if (isGrabbing) {
        mapping = gameMap;
    } else {
        mapping = menuMap;
    }
    
    for (NSMutableDictionary *buttonDict in mapping) {
        if(controllerKeycode == [buttonDict[@"gamepad_button"] intValue]) {
            keycode = [buttonDict[@"keycode"] intValue];
        }
    }

    switch (keycode) {
        case GLFW_KEY_UNKNOWN:
            // Do nothing
            break;
        case -GLFW_KEY_LEFT_SHIFT:
            if (!pressed) {
                leftShiftHeld = !leftShiftHeld;
                sendTrackedKey(GLFW_KEY_LEFT_SHIFT, leftShiftHeld);
            }
            break;
        case SPECIALBTN_MOUSEPRI:
            sendTrackedMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed);
            break;
        case SPECIALBTN_MOUSEMID:
            sendTrackedMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed);
            break;
        case SPECIALBTN_MOUSESEC:
            sendTrackedMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed);
            break;
        case SPECIALBTN_SCROLLUP:
            CallbackBridge_nativeSendScroll(0, pressed ? 1 : 0);
            break;
        case SPECIALBTN_SCROLLDOWN:
            CallbackBridge_nativeSendScroll(0, pressed ? -1 : 0);
            break;
        default:
            if (keycode == GLFW_KEY_LEFT_SHIFT) {
                leftShiftHeld = pressed;
            }
            sendTrackedKey(keycode, pressed);
            break;
    }
}

+ (void)registerControllerCallbacks:(GCController *)controller {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;

    gamepad.leftShoulder.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_BUMPER pressed:pressed];
    };
    gamepad.rightShoulder.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER pressed:pressed];
    };

    gamepad.leftTrigger.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER pressed:pressed];
    };
    gamepad.rightTrigger.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER pressed:pressed];
    };
    gamepad.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_BACK pressed:pressed];
    };
    gamepad.buttonMenu.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_START pressed:pressed];
    };
    gamepad.buttonHome.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_GUIDE pressed:pressed];
    };

    gamepad.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_A pressed:pressed];
    };
    gamepad.buttonB.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_B pressed:pressed];
    };
    gamepad.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_X pressed:pressed];
    };
    gamepad.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_Y pressed:pressed];
    };

    gamepad.dpad.up.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_UP pressed:pressed];
    };
    gamepad.dpad.down.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_DOWN pressed:pressed];
    };
    gamepad.dpad.left.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_LEFT pressed:pressed];
    };
    gamepad.dpad.right.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_RIGHT pressed:pressed];
    };

    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad * _Nonnull dpad, float xValue, float yValue) {
        if (sdlActive) return;

        if (!isGrabbing) {
            // Update virtual mouse position
            lastXValue = xValue;
            lastYValue = yValue;
            return;
        }

        char direction = -1;
        if (xValue != 0 && yValue != 0) {
            CGFloat degree = atan2f(yValue, xValue) * (180.0 / M_PI);
            if (degree < 0) {
                degree += 360;
            }
            direction = (int)((degree+22.5)/45.0) % 8;
        }
        if (lastLThumbDirection == direction) {
            return;
        }

        // Update WASD states
        sendTrackedKey(GLFW_KEY_W,
            direction >= DIRECTION_NORTH_EAST &&
            direction <= DIRECTION_NORTH_WEST);
        sendTrackedKey(GLFW_KEY_A,
            direction >= DIRECTION_NORTH_WEST &&
            direction <= DIRECTION_SOUTH_WEST);
        sendTrackedKey(GLFW_KEY_S,
            direction >= DIRECTION_SOUTH_WEST &&
            direction <= DIRECTION_SOUTH_EAST);
        sendTrackedKey(GLFW_KEY_D,
            direction == DIRECTION_SOUTH_EAST ||
            direction == DIRECTION_EAST ||
            direction == DIRECTION_NORTH_EAST);

        lastLThumbDirection = direction;
    };
    gamepad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad * _Nonnull dpad, float xValue, float yValue) {
        if (sdlActive) return;

        if (isGrabbing) {
            lastXValue = xValue;
            lastYValue = yValue;
        }
    };
    gamepad.leftThumbstickButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_THUMB pressed:pressed];
    };
    gamepad.rightThumbstickButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_THUMB pressed:pressed];
    };
}

/**
 * Send the new mouse position, computing the delta
 */
+ (void)tick {
    [self updateSDLState];
    if (sdlActive) {
        // Avoid a large delta if the built-in mapping resumes
        lastFrameTime = 0;
        return;
    }

    // There isn't a convenient way to get ns, use ms at this point
    CGFloat frameTime = CACurrentMediaTime();
    // GameController automatically performs deadzone calculations
    // so we just take the raw input
    if (lastFrameTime != 0 && (lastXValue != 0 || lastYValue != 0)) {
        CGFloat acceleration = pow(MathUtils_dist(0, 0, lastXValue, lastYValue), MOUSE_MAX_ACCELERATION); // magnitude
        if (acceleration > 1) acceleration = 1;

        // Compute delta since last tick time
        CGFloat deltaX = lastXValue * acceleration * 18;
        CGFloat deltaY = -lastYValue * acceleration * 18;
        CGFloat deltaTimeScale = (frameTime - lastFrameTime) / (1.0/60.0); // Scale of 1 = 60Hz
        deltaX *= deltaTimeScale;
        deltaY *= deltaTimeScale;

        SurfaceViewController *vc = (id)UIWindow.mainWindow.rootViewController;
        [vc sendTouchPoint:CGPointMake(deltaX, deltaY) withEvent:ACTION_MOVE_MOTION];
    }
    lastFrameTime = frameTime;
}

+ (void)unregisterControllerCallbacks:(GCController *)controller {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    gamepad.leftShoulder.pressedChangedHandler = nil;
    gamepad.rightShoulder.pressedChangedHandler = nil;
    gamepad.leftTrigger.pressedChangedHandler = nil;
    gamepad.rightTrigger.pressedChangedHandler = nil;
    gamepad.buttonOptions.pressedChangedHandler = nil;
    gamepad.buttonMenu.pressedChangedHandler = nil;
    gamepad.buttonHome.pressedChangedHandler = nil;
    gamepad.buttonA.pressedChangedHandler = nil;
    gamepad.buttonB.pressedChangedHandler = nil;
    gamepad.buttonX.pressedChangedHandler = nil;
    gamepad.buttonY.pressedChangedHandler = nil;
    gamepad.dpad.up.pressedChangedHandler = nil;
    gamepad.dpad.down.pressedChangedHandler = nil;
    gamepad.dpad.left.pressedChangedHandler = nil;
    gamepad.dpad.right.pressedChangedHandler = nil;
    gamepad.leftThumbstick.valueChangedHandler = nil;
    gamepad.rightThumbstick.valueChangedHandler = nil;
    gamepad.leftThumbstickButton.pressedChangedHandler = nil;
    gamepad.rightThumbstickButton.pressedChangedHandler = nil;
}

@end
