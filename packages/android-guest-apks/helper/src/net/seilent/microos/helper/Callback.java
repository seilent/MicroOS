package net.seilent.microos.helper;

import android.os.Binder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;

final class Callback extends Binder {
    private static final String IFACE = "net.seilent.microos.IBridgeCallback";
    private static final int SET_VOLUME = 1;
    private static final int RADIOS = 2;
    private static final int WIFI_LIST = 3;
    private static final int BT_LIST = 4;
    private static final int RESULT = 5;
    private static final int PROMPT = 6;
    private static final int MAX_ENTRIES = 32;
    private static final int MAX_LOGGED = 10;

    private final HelperApp app;
    private final Bridge bridge;
    private int refusals;

    Callback(HelperApp app, Bridge bridge) {
        this.app = app;
        this.bridge = bridge;
    }

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
        int uid = Binder.getCallingUid();
        if (uid != Process.SYSTEM_UID) {
            if (refusals < MAX_LOGGED) {
                refusals++;
                Log.w(Bridge.TAG, "callback " + code + " from uid " + uid + " refused");
            }
            return false;
        }
        if (code < SET_VOLUME || code > PROMPT) {
            return super.onTransact(code, data, reply, flags);
        }
        try {
            data.enforceInterface(IFACE);
        } catch (SecurityException e) {
            Log.w(Bridge.TAG, "callback " + code + ": not " + IFACE);
            return true;
        }
        Runnable update = null;
        try {
            update = read(code, data);
        } catch (RuntimeException e) {
            Log.w(Bridge.TAG, "callback " + code + ": bad argument");
        }
        bridge.arrived(this, update);
        return true;
    }

    private Runnable read(int code, Parcel data) {
        switch (code) {
            case SET_VOLUME: {
                int index = data.readInt();
                int muted = range(data.readInt(), 0, 1);
                return () -> app.setVolume(index, muted);
            }
            case RADIOS: {
                int wifi = range(data.readInt(), -1, 1);
                int bluetooth = range(data.readInt(), -1, 1);
                String wifiName = text(data);
                String bluetoothName = text(data);
                return () -> app.radios(wifi, bluetooth, wifiName, bluetoothName);
            }
            case WIFI_LIST: {
                int n = range(data.readInt(), 0, MAX_ENTRIES);
                List<HelperApp.Network> networks = new ArrayList<>(n);
                for (int i = 0; i < n; i++) {
                    String id = text(data);
                    String ssid = text(data);
                    range(data.readInt(), 0, 100);
                    int security = range(data.readInt(), 0, 3);
                    int netFlags = range(data.readInt(), 0, 7);
                    networks.add(new HelperApp.Network(id, ssid, security, netFlags));
                }
                return () -> app.networks(networks);
            }
            case BT_LIST: {
                int n = range(data.readInt(), 0, MAX_ENTRIES);
                List<HelperApp.Device> devices = new ArrayList<>(n);
                for (int i = 0; i < n; i++) {
                    String address = text(data);
                    String name = text(data);
                    int devFlags = range(data.readInt(), 0, 7);
                    devices.add(new HelperApp.Device(address, name, devFlags));
                }
                return () -> app.devices(devices);
            }
            case RESULT: {
                int request = data.readInt();
                int result = data.readInt();
                String detail = text(data);
                return () -> {
                    Log.i(Bridge.TAG, "result " + request + " " + result + " " + detail);
                    app.result(request, result);
                };
            }
            default: {
                int prompt = data.readInt();
                int kind = range(data.readInt(), 0, 3);
                String address = text(data);
                String name = text(data);
                int passkey = range(data.readInt(), 0, 999999);
                return () -> app.prompt(prompt, kind, address, name, passkey);
            }
        }
    }

    private static int range(int v, int min, int max) {
        if (v < min || v > max) {
            throw new IllegalArgumentException();
        }
        return v;
    }

    private static String text(Parcel data) {
        String s = data.readString();
        if (s == null) {
            throw new IllegalArgumentException();
        }
        return s;
    }
}
