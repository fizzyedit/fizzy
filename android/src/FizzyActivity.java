package dev.fizzyedit.hello;

import org.libsdl.app.SDLActivity;

public class FizzyActivity extends SDLActivity {
    protected String[] getLibraries() {
        return new String[] { "main" }; // SDL3 is statically linked into it
    }

    // Back with nothing open leaves to the background, never finishes (API 26-30 would kill the app).
    @Override
    public void superOnBackPressed() {
        moveTaskToBack(true);
    }
}
