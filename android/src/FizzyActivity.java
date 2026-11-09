package dev.fizzyedit.hello;

import android.os.Build;
import android.os.Bundle;
import android.graphics.Insets;
import android.view.Display;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsAnimation;
import android.view.WindowManager;
import java.util.List;
import org.libsdl.app.FizzyEdit;
import org.libsdl.app.SDLActivity;

public class FizzyActivity extends SDLActivity {
    protected String[] getLibraries() {
        return new String[] { "main" }; // SDL3 is statically linked into it
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // SDL's input connection lets its text go stale on a delete, garbling what follows a
        // backspace; ours keeps it true, and SDL's ShowTextInputTask reuses this view.
        if (mLayout != null) {
            mTextEdit = new FizzyEdit(this);
            mTextEdit.setVisibility(View.GONE);
            mLayout.addView(mTextEdit);
        }
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
        listenForInsets();
    }

    // The window keeps its size under the keyboard (adjustNothing); the app lays out above it
    // from nativeInsets. SDL's surface keeps its own insets listener: ours is on its parent and
    // returns the insets unchanged, so they still reach it.
    private void listenForInsets() {
        if (Build.VERSION.SDK_INT < 30) {
            getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            return;
        }
        View content = getContentView();
        content.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                v.setPadding(bars.left, bars.top, bars.right, insets.getInsets(WindowInsets.Type.navigationBars()).bottom);
                reportInsets(insets);
                return insets;
            }
        });
        content.setWindowInsetsAnimationCallback(new WindowInsetsAnimation.Callback(WindowInsetsAnimation.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
            @Override
            public WindowInsets onProgress(WindowInsets insets, List<WindowInsetsAnimation> running) {
                reportInsets(insets);
                return insets;
            }
        });
    }

    private void reportInsets(WindowInsets insets) {
        nativeInsets(insets.getInsets(WindowInsets.Type.ime()).bottom,
                insets.getInsets(WindowInsets.Type.navigationBars()).bottom,
                getResources().getDisplayMetrics().density);
    }

    static native void nativeInsets(float imePx, float navPx, float density);

    // Back with nothing open leaves to the background, never finishes (API 26-30 would kill the app).
    @Override
    public void superOnBackPressed() {
        moveTaskToBack(true);
    }
}
