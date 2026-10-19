package cloud.hubera.jobs

import cloud.hubera.id.sso.HuberaIdAccounts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// FragmentActivity requis par local_auth (empreinte / code appareil) sur Android.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAccounts" -> {
                        val rows = HuberaIdAccounts.listAccounts(this).map { it.toMap() }
                        result.success(rows)
                    }
                    "moveToBackground" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "freshAccount" -> {
                        val email = call.argument<String>("email").orEmpty()
                        Thread {
                            val row = HuberaIdAccounts.freshFromId(this, email)?.toMap()
                            runOnUiThread { result.success(row) }
                        }.start()
                    }
                    "saveSession" -> {
                        // Le jeton Jobs ne remplace pas la session Hubera ID.
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "hubera_id_sso"
    }
}
