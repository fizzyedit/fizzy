package dev.fizzyedit.hello;

import org.libsdl.app.SDLActivity;

public class FizzyActivity extends SDLActivity {
    protected String[] getLibraries() {
        return new String[] { "fizzy_hello" }; // SDL3 is statically linked into it
    }
}
