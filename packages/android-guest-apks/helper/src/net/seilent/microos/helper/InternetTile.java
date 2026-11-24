package net.seilent.microos.helper;

public final class InternetTile extends RadioTile {
    @Override
    int radio() {
        return HelperApp.WIFI;
    }
}
