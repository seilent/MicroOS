package net.seilent.microos.helper;

import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

abstract class RadioTile extends TileService implements HelperApp.Listener {
    abstract int radio();

    private HelperApp app() {
        return (HelperApp) getApplication();
    }

    @Override
    public void onStartListening() {
        app().listen(this, true);
        changed();
    }

    @Override
    public void onStopListening() {
        app().listen(this, false);
    }

    @Override
    public void changed() {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        HelperApp app = app();
        int on = app.radio(radio());
        tile.setState(on < 0 ? Tile.STATE_UNAVAILABLE : on == 1 ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        String name = app.names[radio()];
        tile.setSubtitle(on == 1 && !name.isEmpty() ? name : null);
        tile.updateTile();
    }

    @Override
    public void onClick() {
        int on = app().radio(radio());
        if (on >= 0) {
            app().bridge.request(Bridge.SET_RADIO, p -> {
                p.writeInt(radio());
                p.writeInt(1 - on);
            }, 1, null);
        }
    }
}
