import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;

public class RestrictionsStub extends Binder {
    private static final String DESCRIPTOR = "android.content.IRestrictionsManager";

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
        if (code == INTERFACE_TRANSACTION) {
            reply.writeString(DESCRIPTOR);
            return true;
        }
        if (code < FIRST_CALL_TRANSACTION || code > FIRST_CALL_TRANSACTION + 4) {
            return super.onTransact(code, data, reply, flags);
        }
        data.enforceInterface(DESCRIPTOR);
        if (reply != null) {
            reply.writeNoException();
            switch (code - FIRST_CALL_TRANSACTION) {
                case 0:
                    reply.writeInt(1);
                    new Bundle().writeToParcel(reply, 0);
                    break;
                case 1:
                case 4:
                    reply.writeInt(0);
                    break;
            }
        }
        return true;
    }

    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Class<?> sm = Class.forName("android.os.ServiceManager");
        sm.getMethod("addService", String.class, IBinder.class).invoke(null, "restrictions", new RestrictionsStub());
        System.out.println("restrictionsstub: registered");
        Looper.loop();
    }
}
