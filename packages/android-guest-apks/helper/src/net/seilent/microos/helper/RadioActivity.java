package net.seilent.microos.helper;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.CompoundButton;
import android.widget.ListView;
import android.widget.Switch;
import android.widget.TextView;

import java.util.Collections;
import java.util.List;

abstract class RadioActivity<T> extends Activity implements HelperApp.Listener {
    private static final long SETTLE_MS = 2000;

    HelperApp app;
    private Switch toggle;
    private TextView status;
    private ArrayAdapter<String[]> adapter;
    private List<T> shown = Collections.emptyList();
    private AlertDialog dialog;
    private int pending;
    private int pendingCall;
    private final Runnable refresh = this::changed;

    private final CompoundButton.OnCheckedChangeListener flip = (button, on) ->
        app.bridge.request(Bridge.SET_RADIO, p -> {
            p.writeInt(radio());
            p.writeInt(on ? 1 : 0);
        }, 1, r -> {
            if (r == null || r[0] != 0) {
                changed();
            } else {
                toggle.postDelayed(refresh, SETTLE_MS);
            }
        });

    abstract int radio();

    abstract int toggleLabel();

    abstract void failed(int call, int code);

    abstract List<T> items();

    abstract String[] row(T item);

    abstract void tap(T item);

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        app = (HelperApp) getApplication();
        setContentView(R.layout.radio);
        toggle = findViewById(R.id.toggle);
        toggle.setText(toggleLabel());
        status = findViewById(R.id.status);
        adapter = new ArrayAdapter<String[]>(this, android.R.layout.simple_list_item_2, android.R.id.text1) {
            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                View view = super.getView(position, convertView, parent);
                String[] row = getItem(position);
                ((TextView) view.findViewById(android.R.id.text1)).setText(row[0]);
                ((TextView) view.findViewById(android.R.id.text2)).setText(row[1]);
                return view;
            }
        };
        ListView list = findViewById(android.R.id.list);
        list.setAdapter(adapter);
        list.setOnItemClickListener((parent, view, position, id) -> tap(shown.get(position)));
    }

    @Override
    protected void onResume() {
        super.onResume();
        app.listen(this, true);
        app.watch(radio(), true);
        changed();
    }

    @Override
    protected void onPause() {
        app.watch(radio(), false);
        app.listen(this, false);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        toggle.removeCallbacks(refresh);
        closeDialog();
        super.onDestroy();
    }

    @Override
    public void changed() {
        int on = app.radio(radio());
        toggle.setOnCheckedChangeListener(null);
        toggle.setChecked(on == 1);
        toggle.setEnabled(on >= 0);
        toggle.setOnCheckedChangeListener(flip);
        if (on != 1) {
            status(0);
        }
        shown = on == 1 ? items() : Collections.emptyList();
        adapter.clear();
        for (T item : shown) {
            adapter.add(row(item));
        }
    }

    @Override
    public void result(int request, int code) {
        if (request == 0 || request != pending) {
            return;
        }
        pending = 0;
        if (code == 0) {
            status(0);
        } else {
            failed(pendingCall, code);
        }
    }

    void send(int call, Bridge.Args args) {
        status(0);
        app.bridge.request(call, args, 2, r -> {
            if (r == null || r[0] != 0) {
                failed(call, r == null ? -1 : r[0]);
            } else {
                pending = r[1];
                pendingCall = call;
            }
        });
    }

    void status(int text) {
        status.setText(text == 0 ? null : getText(text));
        status.setVisibility(text == 0 ? View.GONE : View.VISIBLE);
    }

    AlertDialog show(AlertDialog.Builder builder) {
        closeDialog();
        dialog = builder.show();
        dialog.getWindow().getDecorView().setFilterTouchesWhenObscured(true);
        return dialog;
    }

    void closeDialog() {
        if (dialog != null) {
            dialog.dismiss();
            dialog = null;
        }
    }
}
