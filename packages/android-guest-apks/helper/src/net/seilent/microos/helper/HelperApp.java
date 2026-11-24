package net.seilent.microos.helper;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.AudioManager;
import android.os.Handler;
import android.util.Log;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class HelperApp extends Application {
    static final int WIFI = 0;
    static final int BLUETOOTH = 1;

    private static final String VOLUME_CHANGED = "android.media.VOLUME_CHANGED_ACTION";
    private static final String STREAM_MUTE_CHANGED = "android.media.STREAM_MUTE_CHANGED_ACTION";
    private static final String EXTRA_STREAM = "android.media.EXTRA_VOLUME_STREAM_TYPE";

    interface Listener {
        default void changed() {
        }

        default void result(int request, int code) {
        }

        default void prompt(int prompt, int kind, String address, String name, int passkey) {
        }
    }

    static final class Network {
        final String id;
        final String ssid;
        final int security;
        final int flags;

        Network(String id, String ssid, int security, int flags) {
            this.id = id;
            this.ssid = ssid;
            this.security = security;
            this.flags = flags;
        }
    }

    static final class Device {
        final String address;
        final String name;
        final int flags;

        Device(String address, String name, int flags) {
            this.address = address;
            this.name = name;
            this.flags = flags;
        }
    }

    Bridge bridge;
    boolean live;
    final int[] radios = {-1, -1};
    final String[] names = {"", ""};
    List<Network> networks = Collections.emptyList();
    List<Device> devices = Collections.emptyList();

    private final List<Listener> listeners = new ArrayList<>();
    private Handler main;
    private AudioManager audio;

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            if (Intent.ACTION_AIRPLANE_MODE_CHANGED.equals(action)) {
                int on = intent.getBooleanExtra("state", false) ? 1 : 0;
                bridge.request(Bridge.SET_AIRPLANE, p -> p.writeInt(on), 1, null);
            } else if (Intent.ACTION_SHUTDOWN.equals(action)) {
                bridge.shutdown(goAsync());
            } else if (intent.getIntExtra(EXTRA_STREAM, -1) == AudioManager.STREAM_MUSIC) {
                bridge.reportVolume();
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        main = new Handler(getMainLooper());
        audio = getSystemService(AudioManager.class);
        bridge = new Bridge(this);
        IntentFilter filter = new IntentFilter();
        filter.addAction(VOLUME_CHANGED);
        filter.addAction(STREAM_MUTE_CHANGED);
        filter.addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED);
        filter.addAction(Intent.ACTION_SHUTDOWN);
        registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
    }

    void post(Runnable r) {
        main.post(r);
    }

    int[] volume() {
        return new int[] {
            audio.getStreamVolume(AudioManager.STREAM_MUSIC),
            audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            audio.isStreamMute(AudioManager.STREAM_MUSIC) ? 1 : 0,
        };
    }

    void setVolume(int index, int muted) {
        if (index < 0 || index > audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)) {
            Log.w(Bridge.TAG, "setVolume " + index + " out of range");
            return;
        }
        if (muted == 0 || index > 0) {
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0);
        }
        if (muted == 1) {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0);
        }
    }

    void listen(Listener l, boolean on) {
        if (on) {
            listeners.add(l);
        } else {
            listeners.remove(l);
        }
    }

    void watch(int radio, boolean on) {
        bridge.watch(radio == WIFI ? Bridge.WATCH_WIFI : Bridge.WATCH_BLUETOOTH, on);
    }

    int radio(int radio) {
        return live ? radios[radio] : -1;
    }

    void setLive(boolean on) {
        live = on;
        if (!on) {
            radios[WIFI] = -1;
            radios[BLUETOOTH] = -1;
            names[WIFI] = "";
            names[BLUETOOTH] = "";
            networks = Collections.emptyList();
            devices = Collections.emptyList();
        }
        changed();
    }

    void radios(int wifi, int bluetooth, String wifiName, String bluetoothName) {
        radios[WIFI] = wifi;
        radios[BLUETOOTH] = bluetooth;
        names[WIFI] = wifiName;
        names[BLUETOOTH] = bluetoothName;
        changed();
    }

    void networks(List<Network> list) {
        networks = list;
        changed();
    }

    void devices(List<Device> list) {
        devices = list;
        changed();
    }

    void result(int request, int code) {
        for (Listener l : new ArrayList<>(listeners)) {
            l.result(request, code);
        }
    }

    void prompt(int prompt, int kind, String address, String name, int passkey) {
        for (Listener l : new ArrayList<>(listeners)) {
            l.prompt(prompt, kind, address, name, passkey);
        }
    }

    private void changed() {
        for (Listener l : new ArrayList<>(listeners)) {
            l.changed();
        }
    }
}
