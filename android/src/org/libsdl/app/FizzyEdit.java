package org.libsdl.app;

import android.content.Context;
import android.text.Editable;
import android.text.Selection;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

// In SDL's package because SDLDummyEdit's constructor and SDLInputConnection are package-private.
public class FizzyEdit extends SDLDummyEdit {
    public FizzyEdit(Context c) {
        super(c);
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo out) {
        super.onCreateInputConnection(out); // fills out
        ic = new FizzyInputConnection(this);
        return ic;
    }

    // The app changed the field itself (cleared it, moved the caret): the connection's Editable and
    // committed text only follow the keyboard's edits, so start both again from `before`, the
    // text before the caret, and have the keyboard read it anew.
    void reset(String before) {
        if (!(ic instanceof FizzyInputConnection)) return;
        FizzyInputConnection fic = (FizzyInputConnection) ic;
        Editable e = fic.getEditable();
        if (e != null) {
            e.replace(0, e.length(), before);
            Selection.setSelection(e, e.length());
            BaseInputConnection.removeComposingSpans(e);
        }
        fic.mCommittedText = before;
        Log.i(FizzyInputConnection.TAG, "reset(\"" + before + "\")");
        InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.restartInput(this);
    }
}

// SDL's deleteSurroundingText sends backspaces without deleting from its Editable, and a DEL key
// goes to SDLActivity.handleKeyEvent, which never touches it either: the next updateText then
// diffs a stale Editable. Here every delete edits the Editable, and updateText sends the difference.
class FizzyInputConnection extends SDLInputConnection {
    static final String TAG = "fizzy-ime";

    FizzyInputConnection(View v) {
        super(v, true);
    }

    @Override
    public boolean commitText(CharSequence text, int newCursorPosition) {
        boolean r = super.commitText(text, newCursorPosition);
        log("commitText(\"" + text + "\", " + newCursorPosition + ")");
        return r;
    }

    @Override
    public boolean setComposingText(CharSequence text, int newCursorPosition) {
        boolean r = super.setComposingText(text, newCursorPosition);
        log("setComposingText(\"" + text + "\", " + newCursorPosition + ")");
        return r;
    }

    @Override
    public boolean setComposingRegion(int start, int end) {
        boolean r = super.setComposingRegion(start, end);
        log("setComposingRegion(" + start + ", " + end + ")");
        return r;
    }

    @Override
    public boolean finishComposingText() {
        boolean r = super.finishComposingText();
        log("finishComposingText()");
        return r;
    }

    @Override
    public boolean deleteSurroundingText(int before, int after) {
        Editable e = getEditable();
        if (e != null) {
            int len = e.length();
            int a = clamp(Selection.getSelectionStart(e), len), b = clamp(Selection.getSelectionEnd(e), len);
            if (a > b) {
                int t = a;
                a = b;
                b = t;
            }
            int end = Math.min(len, b + Math.max(0, after));
            if (end < len && end > b && Character.isLowSurrogate(e.charAt(end)) && Character.isHighSurrogate(e.charAt(end - 1))) end--;
            e.delete(b, end);
            int start = Math.max(0, a - Math.max(0, before));
            if (start > 0 && start < a && Character.isLowSurrogate(e.charAt(start)) && Character.isHighSurrogate(e.charAt(start - 1))) start--;
            e.delete(start, a);
            updateText();
        }
        log("deleteSurroundingText(" + before + ", " + after + ")");
        return true;
    }

    @Override
    public boolean sendKeyEvent(KeyEvent ev) {
        if (ev.getKeyCode() != KeyEvent.KEYCODE_DEL) return super.sendKeyEvent(ev);
        if (ev.getAction() == KeyEvent.ACTION_DOWN) {
            Editable e = getEditable();
            if (e != null) {
                int len = e.length();
                int a = clamp(Selection.getSelectionStart(e), len), b = clamp(Selection.getSelectionEnd(e), len);
                if (a > b) {
                    int t = a;
                    a = b;
                    b = t;
                }
                if (a != b) {
                    e.delete(a, b);
                } else if (a > 0) {
                    e.delete(Character.offsetByCodePoints(e, a, -1), a);
                }
                updateText();
            }
            log("sendKeyEvent(DEL)");
        }
        return true; // DOWN and UP: SDLActivity.handleKeyEvent would send a second backspace
    }

    private static int clamp(int i, int len) {
        return Math.max(0, Math.min(len, i));
    }

    private void log(String call) {
        if (Log.isLoggable(TAG, Log.VERBOSE)) Log.v(TAG, call + " -> \"" + getEditable() + "\"");
    }
}
