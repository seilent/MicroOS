package net.seilent.microos.helper;

import android.content.BroadcastReceiver;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.Arrays;

final class Bridge {
    static final String TAG = "MicroOsHelper";
    static final int HELLO = 1;
    static final int REPORT_VOLUME = 2;
    static final int SET_RADIO = 3;
    static final int SET_AIRPLANE = 4;
    static final int WATCH_WIFI = 5;
    static final int CONNECT_WIFI = 6;
    static final int WATCH_BLUETOOTH = 7;
    static final int CONNECT_BLUETOOTH = 8;
    static final int PAIR_BLUETOOTH = 9;
    static final int ANSWER_PAIRING = 10;
    static final int POWER = 11;

    private static final String NAME = "microosbridge";
    private static final String IFACE = "net.seilent.microos.IBridge";
    private static final long RETRY_MS = 2000;

    interface Args {
        void write(Parcel p);
    }

    interface Reply {
        void done(int[] reply);
    }

    private final HelperApp app;
    private final Handler handler;
    private final Runnable lookup = this::lookup;
    private final Runnable noCallback = this::noCallback;
    private Method checkService;
    private IBinder remote;
    private IBinder.DeathRecipient death;
    private Callback callback;
    private boolean helloOk;
    private boolean live;
    private boolean watchWifi;
    private boolean watchBluetooth;
    private boolean toldWifi;
    private boolean toldBluetooth;
    private int[] lastVolume;

    Bridge(HelperApp app) {
        this.app = app;
        HandlerThread thread = new HandlerThread("bridge");
        thread.start();
        handler = new Handler(thread.getLooper());
        handler.post(lookup);
    }

    void request(int code, Args args, int replyInts, Reply reply) {
        handler.post(() -> {
            int[] r = live ? invoke(code, args, replyInts) : null;
            if (reply != null) {
                app.post(() -> reply.done(r));
            }
        });
    }

    void watch(int code, boolean on) {
        handler.post(() -> {
            if (code == WATCH_WIFI) {
                watchWifi = on;
            } else {
                watchBluetooth = on;
            }
            if (live) {
                syncWatches();
            }
        });
    }

    void reportVolume() {
        handler.post(this::sendVolume);
    }

    void shutdown(BroadcastReceiver.PendingResult pending) {
        handler.post(() -> {
            String reason = shutdownReason();
            if (!reason.equals("0userrequested") && !reason.equals("1userrequested")) {
                Log.i(TAG, "power " + reason + " not sent");
            } else if (!live) {
                Log.i(TAG, "power " + reason + " not sent, no bridge");
            } else {
                Log.i(TAG, "power " + reason + " sent");
                invoke(POWER, p -> p.writeString(reason), 1);
            }
            pending.finish();
        });
    }

    private void lookup() {
        IBinder b;
        try {
            if (checkService == null) {
                checkService = Class.forName("android.os.ServiceManager").getMethod("checkService", String.class);
            }
            b = (IBinder) checkService.invoke(null, NAME);
        } catch (ReflectiveOperationException e) {
            Log.e(TAG, "ServiceManager.checkService is not reachable", e);
            return;
        }
        if (b == null) {
            handler.postDelayed(lookup, RETRY_MS);
            return;
        }
        IBinder.DeathRecipient d = () -> handler.post(() -> died(b));
        try {
            b.linkToDeath(d, 0);
        } catch (RemoteException e) {
            handler.postDelayed(lookup, RETRY_MS);
            return;
        }
        remote = b;
        death = d;
        callback = new Callback(app, this);
        Callback cb = callback;
        int[] r = invoke(HELLO, p -> {
            p.writeInt(1);
            p.writeStrongBinder(cb);
        }, 1);
        if (r == null || r[0] != 0) {
            drop();
            handler.postDelayed(lookup, RETRY_MS);
            return;
        }
        helloOk = true;
        handler.postDelayed(noCallback, RETRY_MS);
    }

    void arrived(Callback cb, Runnable update) {
        handler.post(() -> {
            if (cb != callback || !helloOk) {
                return;
            }
            if (!live) {
                live = true;
                handler.removeCallbacks(noCallback);
                Log.i(TAG, "bridge live");
                app.post(() -> app.setLive(true));
                lastVolume = null;
                sendVolume();
                syncWatches();
            }
            if (update != null) {
                app.post(update);
            }
        });
    }

    private void syncWatches() {
        if (toldWifi != watchWifi) {
            toldWifi = watchWifi;
            invoke(WATCH_WIFI, p -> p.writeInt(toldWifi ? 1 : 0), 1);
        }
        if (toldBluetooth != watchBluetooth) {
            toldBluetooth = watchBluetooth;
            invoke(WATCH_BLUETOOTH, p -> p.writeInt(toldBluetooth ? 1 : 0), 1);
        }
    }

    private void noCallback() {
        Log.i(TAG, "no callback within " + RETRY_MS + " ms of hello");
        drop();
        lookup();
    }

    private void died(IBinder b) {
        if (b != remote) {
            return;
        }
        Log.i(TAG, "bridge died");
        death = null;
        toldWifi = false;
        toldBluetooth = false;
        drop();
        handler.postDelayed(lookup, RETRY_MS);
    }

    private void drop() {
        handler.removeCallbacks(noCallback);
        if (death != null) {
            remote.unlinkToDeath(death, 0);
        }
        remote = null;
        death = null;
        callback = null;
        helloOk = false;
        if (live) {
            live = false;
            app.post(() -> app.setLive(false));
        }
    }

    private void sendVolume() {
        if (!live) {
            return;
        }
        int[] v = app.volume();
        if (Arrays.equals(v, lastVolume)) {
            return;
        }
        lastVolume = v;
        Parcel data = Parcel.obtain();
        try {
            data.writeInterfaceToken(IFACE);
            data.writeInt(v[0]);
            data.writeInt(v[1]);
            data.writeInt(v[2]);
            remote.transact(REPORT_VOLUME, data, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException e) {
            Log.w(TAG, "call " + REPORT_VOLUME + ": " + e.getClass().getSimpleName());
        } finally {
            data.recycle();
        }
    }

    private int[] invoke(int code, Args args, int replyInts) {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(IFACE);
            args.write(data);
            if (!remote.transact(code, data, reply, 0)) {
                Log.w(TAG, "call " + code + ": unknown transaction");
                return null;
            }
            reply.readException();
            int[] r = new int[replyInts];
            for (int i = 0; i < replyInts; i++) {
                r[i] = reply.readInt();
            }
            if (r[0] != 0) {
                Log.i(TAG, "call " + code + " result " + r[0]);
            }
            return r;
        } catch (RemoteException | RuntimeException e) {
            Log.w(TAG, "call " + code + ": " + e.getClass().getSimpleName());
            return null;
        } finally {
            data.recycle();
            reply.recycle();
        }
    }

    private static String shutdownReason() {
        try {
            return (String) Class.forName("android.os.SystemProperties").getMethod("get", String.class)
                .invoke(null, "sys.shutdown.requested");
        } catch (ReflectiveOperationException e) {
            Log.e(TAG, "SystemProperties.get is not reachable", e);
            return "";
        }
    }
}
