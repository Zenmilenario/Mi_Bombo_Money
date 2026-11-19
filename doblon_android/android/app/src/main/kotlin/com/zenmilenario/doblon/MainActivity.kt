package com.zenmilenario.doblon

import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity: the app lock (fingerprint or the phone's PIN) needs a fragment activity.
class MainActivity : FlutterFragmentActivity() {
    // With the lock on, the recent apps view shows no picture of the app (Android 13 and later). Screenshots still
    // work, unlike FLAG_SECURE. On earlier versions, Flutter's own cover (lib/main.dart) hides the content.
    override fun onResume() {
        super.onResume()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val lock = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).getBoolean("flutter.lockEnabled", false)
            setRecentsScreenshotEnabled(!lock)
        }
    }
}
