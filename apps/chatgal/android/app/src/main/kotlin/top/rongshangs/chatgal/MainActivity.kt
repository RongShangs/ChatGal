package top.rongshangs.chatgal

import android.app.ActivityManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * This device's recents card mis-decodes ApplicationInfo.loadLabel
 * (UTF-8-as-GBK), even when the APK label is correct UTF-16.
 * TaskDescription with Unicode code points is the only reliable override.
 * Color is left 0 so the overview card does not animate a recolor
 * (that previously delayed the title by ~2s).
 *
 * 另外这里挂三条原生通道（避免为三件小事各引一个 pub 依赖）：
 * * `chatgal/media`   —— 朗读音频的播放/停止（MediaPlayer）
 * * `chatgal/webview` —— 打开隐私政策网页（原生 WebView 页）
 * * `chatgal/system`  —— 把 mailto: / mqqwpa: 之类交给系统处理
 *
 * 播放回调**必须分开报完成与错误**，并带上任务编号：以前两者都发 `completed`，
 * Dart 侧分不出「正常播完」和「文件根本放不出来」，还会让旧任务的回调结束新任务。
 */
class MainActivity : FlutterActivity() {

    private var player: MediaPlayer? = null
    private var mediaChannel: MethodChannel? = null

    /** 当前播放任务编号（Dart 侧每次朗读 +1）；null = 没有任务在播。 */
    private var currentTaskId: Int? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyTaskLabel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val media = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
        mediaChannel = media
        media.setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    val path = call.argument<String>("path")
                    val taskId = call.argument<Number>("taskId")?.toInt() ?: 0
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "path is required", null)
                    } else {
                        try {
                            playFile(path, taskId)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("play_failed", e.message ?: "play failed", null)
                        }
                    }
                }
                "stop" -> {
                    stopPlayback()
                    result.success(null)
                }
                "isPlaying" -> result.success(player?.isPlaying == true)
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEBVIEW_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            try {
                                val intent = android.content.Intent(
                                    this,
                                    PrivacyWebViewActivity::class.java
                                )
                                intent.putExtra(PrivacyWebViewActivity.EXTRA_URL, url)
                                intent.putExtra(
                                    PrivacyWebViewActivity.EXTRA_TITLE,
                                    call.argument<String>("title") ?: ""
                                )
                                intent.putExtra(
                                    PrivacyWebViewActivity.EXTRA_ACCENT,
                                    call.argument<Number>("accent")?.toInt()
                                        ?: PrivacyWebViewActivity.DEFAULT_ACCENT
                                )
                                intent.putExtra(
                                    PrivacyWebViewActivity.EXTRA_DARK,
                                    call.argument<Boolean>("dark") ?: false
                                )
                                startActivity(intent)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("open_failed", e.message ?: "open failed", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 反馈入口：mailto: / mqqwpa:// 这类交给系统处理。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launch" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            try {
                                val intent = android.content.Intent(
                                    android.content.Intent.ACTION_VIEW,
                                    android.net.Uri.parse(url)
                                )
                                intent.addFlags(
                                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                                startActivity(intent)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("launch_failed", e.message ?: "no app", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 只播本地文件（TTS 结果先落盘再播），不处理网络流。 */
    private fun playFile(path: String, taskId: Int) {
        stopPlayback()
        val mp = MediaPlayer()
        player = mp
        currentTaskId = taskId
        mp.setOnPreparedListener { prepared ->
            // 准备期间可能已经被 stop / 换了新任务：这时不要开播。
            if (currentTaskId != taskId) {
                releaseQuietly(prepared)
                return@setOnPreparedListener
            }
            prepared.start()
        }
        mp.setOnCompletionListener { finishTask(taskId, null) }
        mp.setOnErrorListener { _, what, extra ->
            finishTask(taskId, "what=$what extra=$extra")
            true
        }
        try {
            mp.setDataSource(path)
            // 异步准备：在平台线程上同步 prepare 会卡住 UI（大文件尤其明显）。
            mp.prepareAsync()
        } catch (e: Exception) {
            finishTask(taskId, e.message ?: "prepare failed")
        }
    }

    /** 播完 / 出错统一收尾，并把结果（带任务编号）报回 Dart。 */
    private fun finishTask(taskId: Int, error: String?) {
        if (currentTaskId == taskId) {
            currentTaskId = null
            val mp = player
            player = null
            if (mp != null) releaseQuietly(mp)
        }
        mediaChannel?.invokeMethod(
            if (error == null) "completed" else "error",
            mapOf("taskId" to taskId, "message" to error)
        )
    }

    /** 停播：不发回调（Dart 侧发起停止时自己知道）。 */
    private fun stopPlayback() {
        currentTaskId = null
        val mp = player ?: return
        player = null
        try {
            if (mp.isPlaying) mp.stop()
        } catch (_: Exception) {
            // 已经播完或状态非法：忽略，直接释放。
        }
        releaseQuietly(mp)
    }

    private fun releaseQuietly(mp: MediaPlayer) {
        try {
            mp.reset()
        } catch (_: Exception) {
        }
        try {
            mp.release()
        } catch (_: Exception) {
        }
    }

    override fun onPause() {
        applyTaskLabel()
        super.onPause()
    }

    override fun onPostResume() {
        super.onPostResume()
        applyTaskLabel()
        window?.decorView?.post { applyTaskLabel() }
    }

    override fun onDestroy() {
        stopPlayback()
        mediaChannel = null
        super.onDestroy()
    }

    private fun applyTaskLabel() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                setTaskDescription(
                    ActivityManager.TaskDescription(
                        appLabel(),
                        null,
                        0
                    )
                )
            }
        } catch (_: Exception) {
            // Activity may not be attached yet.
        }
    }

    /**
     * Recents card label. Latin "ChatGal" needs no resource decode and avoids
     * the old UTF-8-as-GBK misread that flipped the title to 你好戒戒 ~2s later.
     * Still forced via TaskDescription so system/launcher races don't replace it.
     */
    private fun appLabel(): String = "ChatGal"

    companion object {
        private const val MEDIA_CHANNEL = "chatgal/media"
        private const val WEBVIEW_CHANNEL = "chatgal/webview"
        private const val SYSTEM_CHANNEL = "chatgal/system"
    }
}
