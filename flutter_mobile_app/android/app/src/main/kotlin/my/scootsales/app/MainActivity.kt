package my.scootsales.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

const val NOTIFICATION_PERMISSION_REQUEST = 7402

class MainActivity : FlutterFragmentActivity() {
    private var onDeviceSpeechController: OnDeviceSpeechController? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        onDeviceSpeechController = OnDeviceSpeechController(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "my.scootsales.app/notifications",
        ).setMethodCallHandler { call, result ->
            if (call.method != "request") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST,
                )
            }
            result.success(null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        onDeviceSpeechController?.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        onDeviceSpeechController?.dispose()
        onDeviceSpeechController = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
