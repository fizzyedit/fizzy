package dev.fizzyedit.hello;

import android.os.Build;
import android.os.Bundle;
import android.view.Display;
import android.view.WindowManager;
import org.libsdl.app.SDLActivity;

public class FizzyActivity extends SDLActivity {
    protected String[] getLibraries() {
        return new String[] { "main" }; // SDL3 is statically linked into it
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Android gives an app 60 Hz unless it asks: take the panel's fastest mode at its resolution.
        Display display = Build.VERSION.SDK_INT >= 30 ? getDisplay() : getWindowManager().getDefaultDisplay();
        Display.Mode current = display.getMode(), best = current;
        for (Display.Mode m : display.getSupportedModes()) {
            if (m.getPhysicalWidth() == current.getPhysicalWidth() && m.getPhysicalHeight() == current.getPhysicalHeight()
                    && m.getRefreshRate() > best.getRefreshRate()) best = m;
        }
        WindowManager.LayoutParams params = getWindow().getAttributes();
        params.preferredDisplayModeId = best.getModeId();
        getWindow().setAttributes(params);
    }

    // Back with nothing open leaves to the background, never finishes (API 26-30 would kill the app).
    @Override
    public void superOnBackPressed() {
        moveTaskToBack(true);
    }
}
