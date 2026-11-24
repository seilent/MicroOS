package net.seilent.microos.helper;

import android.app.AlertDialog;
import android.text.Editable;
import android.text.TextWatcher;
import android.widget.Button;
import android.widget.EditText;

import java.util.List;

public final class WifiActivity extends RadioActivity<HelperApp.Network> {
    private static final int ACTIVE = 1;
    private static final int SAVED = 2;
    private static final int PROFILE = 4;
    private static final int PERSONAL = 1;
    private static final int UNSUPPORTED = 2;
    private static final int AUTH = 11;

    private HelperApp.Network last;

    @Override
    int radio() {
        return HelperApp.WIFI;
    }

    @Override
    int toggleLabel() {
        return R.string.use_wifi;
    }

    @Override
    void failed(int call, int code) {
        status(code == AUTH ? R.string.wrong_password : R.string.failed);
        if (code == AUTH && last != null && (last.flags & PROFILE) != 0) {
            askPassword(last);
        }
    }

    @Override
    List<HelperApp.Network> items() {
        return app.networks;
    }

    @Override
    String[] row(HelperApp.Network n) {
        int summary = (n.flags & ACTIVE) != 0 ? R.string.connected
            : (n.flags & SAVED) != 0 ? R.string.saved
            : n.security == UNSUPPORTED ? R.string.unsupported
            : n.security == PERSONAL ? R.string.secured : 0;
        return new String[] {n.ssid, summary == 0 ? "" : getString(summary)};
    }

    @Override
    void tap(HelperApp.Network n) {
        if ((n.flags & ACTIVE) != 0) {
            return;
        }
        if (n.security == UNSUPPORTED) {
            status(R.string.unsupported);
        } else if (n.security == PERSONAL && (n.flags & SAVED) == 0) {
            askPassword(n);
        } else {
            connect(n, "");
        }
    }

    private void connect(HelperApp.Network n, String password) {
        last = n;
        send(Bridge.CONNECT_WIFI, p -> {
            p.writeString(n.id);
            p.writeString(password);
        });
    }

    private void askPassword(HelperApp.Network n) {
        AlertDialog dialog = show(new AlertDialog.Builder(this)
            .setTitle(n.ssid)
            .setView(R.layout.password)
            .setPositiveButton(R.string.connect, (d, which) ->
                connect(n, ((EditText) ((AlertDialog) d).findViewById(R.id.password)).getText().toString()))
            .setNegativeButton(android.R.string.cancel, null));
        Button button = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
        button.setEnabled(false);
        ((EditText) dialog.findViewById(R.id.password)).addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {
            }

            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                button.setEnabled(valid(s.toString()));
            }
        });
    }

    private static boolean valid(String password) {
        int n = password.length();
        return n >= 8 && n <= 63 || n == 64 && password.matches("[0-9A-Fa-f]+");
    }
}
