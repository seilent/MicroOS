package net.seilent.microos.helper;

public final class BluetoothTile extends RadioTile {
    @Override
    int radio() {
        return HelperApp.BLUETOOTH;
    }
}
