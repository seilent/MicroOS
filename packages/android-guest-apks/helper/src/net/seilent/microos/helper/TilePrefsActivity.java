package net.seilent.microos.helper;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Bundle;

public final class TilePrefsActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Object tile = getIntent().getParcelableExtra(Intent.EXTRA_COMPONENT_NAME);
        boolean bluetooth = tile instanceof ComponentName
            && BluetoothTile.class.getName().equals(((ComponentName) tile).getClassName());
        startActivity(new Intent(this, bluetooth ? BluetoothActivity.class : WifiActivity.class));
        finish();
    }
}
