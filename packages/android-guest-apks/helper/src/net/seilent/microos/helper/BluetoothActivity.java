package net.seilent.microos.helper;

import android.app.AlertDialog;

import java.util.List;
import java.util.Locale;

public final class BluetoothActivity extends RadioActivity<HelperApp.Device> {
    private static final int PAIRED = 1;
    private static final int CONNECTED = 2;
    private static final int SHOW_PASSKEY = 1;
    private static final int AUTHORIZE = 2;
    private static final int CANCEL = 3;

    private int dialogPrompt;

    @Override
    int radio() {
        return HelperApp.BLUETOOTH;
    }

    @Override
    int toggleLabel() {
        return R.string.use_bluetooth;
    }

    @Override
    void failed(int call, int code) {
        status(call == Bridge.PAIR_BLUETOOTH ? R.string.pair_failed : R.string.failed);
    }

    @Override
    List<HelperApp.Device> items() {
        return app.devices;
    }

    @Override
    String[] row(HelperApp.Device d) {
        int summary = (d.flags & CONNECTED) != 0 ? R.string.connected : (d.flags & PAIRED) != 0 ? R.string.paired : 0;
        return new String[] {label(d.name, d.address), summary == 0 ? "" : getString(summary)};
    }

    @Override
    void tap(HelperApp.Device d) {
        if ((d.flags & PAIRED) != 0) {
            send(Bridge.CONNECT_BLUETOOTH, p -> {
                p.writeString(d.address);
                p.writeInt((d.flags & CONNECTED) != 0 ? 0 : 1);
            });
        } else {
            send(Bridge.PAIR_BLUETOOTH, p -> p.writeString(d.address));
        }
    }

    @Override
    public void prompt(int prompt, int kind, String address, String name, int passkey) {
        if (kind == CANCEL) {
            if (prompt == dialogPrompt) {
                closeDialog();
            }
            return;
        }
        AlertDialog.Builder b = new AlertDialog.Builder(this)
            .setTitle(getString(R.string.pair_title, label(name, address)));
        if (kind != AUTHORIZE) {
            b.setMessage(String.format(Locale.ROOT, "%06d", passkey));
        }
        if (kind == SHOW_PASSKEY) {
            b.setPositiveButton(android.R.string.ok, null);
        } else {
            b.setPositiveButton(R.string.pair, (d, which) -> answer(prompt, 1))
                .setNegativeButton(android.R.string.cancel, (d, which) -> answer(prompt, 0))
                .setOnCancelListener(d -> answer(prompt, 0));
        }
        show(b);
        dialogPrompt = prompt;
    }

    private void answer(int prompt, int accept) {
        app.bridge.request(Bridge.ANSWER_PAIRING, p -> {
            p.writeInt(prompt);
            p.writeInt(accept);
        }, 1, null);
    }

    private static String label(String name, String address) {
        return name.isEmpty() ? address : name;
    }
}
