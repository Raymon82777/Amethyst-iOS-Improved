/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 */
package org.lwjgl.glfw;

import org.lwjgl.system.*;
import org.lwjgl.system.libffi.*;

import static org.lwjgl.system.APIUtil.*;
import static org.lwjgl.system.MemoryUtil.*;
import static org.lwjgl.system.libffi.LibFFI.*;

/**
 * Instances of this interface may be passed to the {@link GLFW#glfwSetIMEStatusCallback SetIMEStatusCallback} method.
 *
 * <p>Backport of the LWJGL 3.4 interface to the LWJGL 3.3 callback API.</p>
 *
 * <h3>Type</h3>
 *
 * <pre><code>
 * void (*{@link #invoke}) (
 *     GLFWwindow *window
 * )</code></pre>
 */
@FunctionalInterface
@NativeType("GLFWimestatusfun")
public interface GLFWIMEStatusCallbackI extends CallbackI {

    FFICIF CIF = apiCreateCIF(
        FFI_DEFAULT_ABI,
        ffi_type_void,
        ffi_type_pointer
    );

    @Override
    default FFICIF getCallInterface() { return CIF; }

    @Override
    default void callback(long ret, long args) {
        invoke(
            memGetAddress(memGetAddress(args))
        );
    }

    void invoke(@NativeType("GLFWwindow *") long window);

}
