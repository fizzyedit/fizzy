package dev.fizzyedit.hello;

import android.os.Build;
import android.os.Bundle;
import android.graphics.Insets;
import android.view.Display;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
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
        // SDL sets the cutout mode on getAttributes() without setAttributes, so full screen could
        // stay letterboxed under the cutout.
        if (Build.VERSION.SDK_INT >= 28) params.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().setAttributes(params);
        listenForInsets();
    }

    // The window keeps its size under the keyboard (adjustNothing); the app lays out above it
    // from nativeInsets. SDL's surface keeps its own insets listener: ours is on its parent and
    // returns the insets unchanged, so they still reach it. With the bars shown the surface is
    // padded clear of them and the cutout; hidden (full screen) it reaches the edges, and the
    // cutout goes to the app as safe insets.
    private void listenForInsets() {
        if (Build.VERSION.SDK_INT < 30) {
            getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            return;
        }
        View content = getContentView();
        content.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                if (insets.isVisible(WindowInsets.Type.statusBars())) {
                    Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                    v.setPadding(bars.left, bars.top, bars.right, insets.getInsets(WindowInsets.Type.navigationBars()).bottom);
                } else {
                    v.setPadding(0, 0, 0, 0);
                }
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
        Insets safe = insets.isVisible(WindowInsets.Type.statusBars()) ? Insets.NONE : insets.getInsets(WindowInsets.Type.displayCutout());
        nativeInsets(insets.getInsets(WindowInsets.Type.ime()).bottom,
                insets.getInsets(WindowInsets.Type.navigationBars()).bottom,
                getResources().getDisplayMetrics().density,
                safe.left, safe.top, safe.right, safe.bottom);
    }

    // Called from the app's frame (SDLBackend.imeReset) when the app, not the keyboard, changed the
    // focused field: the keyboard's copy of it is stale. `before` is the text before the caret.
    public static void imeReset(final String before) {
        final SDLActivity activity = mSingleton;
        if (activity == null) return;
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (mTextEdit instanceof FizzyEdit) ((FizzyEdit) mTextEdit).reset(before);
            }
        });
    }

    static native void nativeInsets(float imePx, float navPx, float density, float safeLeftPx, float safeTopPx, float safeRightPx, float safeBottomPx);

    // Coming back to the window (Home then back, a dialog closing) can show the bars again: hide
    // them while SDL is full screen. Below API 30 SDL's immersive-sticky flags already do this.
    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        hideSystemBars();
    }

    @Override
    protected void onResume() {
        super.onResume();
        hideSystemBars();
    }

    private void hideSystemBars() {
        if (!mFullscreenModeActive || Build.VERSION.SDK_INT < 30) return;
        getWindow().setDecorFitsSystemWindows(false);
        WindowInsetsController controller = getWindow().getInsetsController();
        if (controller == null) return;
        controller.hide(WindowInsets.Type.systemBars());
        controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    }

    // Back with nothing open leaves to the background, never finishes (API 26-30 would kill the app).
    @Override
    public void superOnBackPressed() {
        moveTaskToBack(true);
    }
}
