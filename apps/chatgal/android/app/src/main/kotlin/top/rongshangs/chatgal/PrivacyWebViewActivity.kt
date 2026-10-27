package top.rongshangs.chatgal

import android.annotation.SuppressLint
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * 轻量原生 WebView 页：只用来显示一个网页（隐私政策占位）。
 *
 * 为什么不引 webview_flutter：这一页不需要 Flutter 与 JS 互通，
 * 原生 WebView 三十来行就够，还能少一个插件依赖与一份 AAR。
 * 顶栏的颜色/明暗由 Dart 侧按当前主题传进来，视觉上不至于跳。
 */
class PrivacyWebViewActivity : android.app.Activity() {

    private var webView: WebView? = null
    private var progress: ProgressBar? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val url = intent.getStringExtra(EXTRA_URL) ?: ""
        val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
        val accent = intent.getIntExtra(EXTRA_ACCENT, DEFAULT_ACCENT)
        val dark = intent.getBooleanExtra(EXTRA_DARK, false)

        val barBack = if (dark) Color.parseColor("#1E1E1E") else Color.WHITE
        val ink = if (dark) Color.parseColor("#E0E0E0") else Color.parseColor("#333333")
        val pageBack = if (dark) Color.parseColor("#121212") else Color.WHITE

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(pageBack)
        }

        // ---- 顶栏：标题 + 关闭 ----
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(barBack)
            setPadding(dp(16), dp(10), dp(8), dp(10))
        }
        val titleView = TextView(this).apply {
            text = if (title.isEmpty()) "隐私政策" else title
            setTextColor(ink)
            setTypeface(null, Typeface.BOLD)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val close = TextView(this).apply {
            text = "✕"
            setTextColor(accent)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            setOnClickListener { finish() }
        }
        bar.addView(titleView)
        bar.addView(close)

        // ---- 进度条：加载时可见，到 100% 收起 ----
        progress = ProgressBar(
            this,
            null,
            android.R.attr.progressBarStyleHorizontal
        ).apply {
            max = 100
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(2)
            )
            progressDrawable.setTint(accent)
        }

        // ---- WebView ----
        val web = WebView(this)
        webView = web
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.setBackgroundColor(pageBack)
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean = false
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                val p = progress ?: return
                if (newProgress >= 100) {
                    p.visibility = View.GONE
                } else {
                    p.visibility = View.VISIBLE
                    p.progress = newProgress
                }
            }
        }

        // 顶栏底部一条细分割线，避免白底白栏糊在一起。
        val divider = View(this).apply {
            setBackgroundColor(
                if (dark) Color.parseColor("#2A2A2A") else Color.parseColor("#ECECEC")
            )
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(1)
            )
        }

        root.addView(bar)
        root.addView(divider)
        root.addView(progress)
        root.addView(
            web,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        )
        setContentView(root)

        if (url.isNotEmpty()) web.loadUrl(url)
    }

    /** 返回键先回退网页历史，退到头才关页面。 */
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val web = webView
        if (web != null && web.canGoBack()) {
            web.goBack()
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        webView?.apply {
            stopLoading()
            loadUrl("about:blank")
            destroy()
        }
        webView = null
        progress = null
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ACCENT = "accent"
        const val EXTRA_DARK = "dark"
        /** 默认主题色 = 浅色·紫罗兰的 accent（0xFFAA96DA）。 */
        const val DEFAULT_ACCENT = 0xFFAA96DA.toInt()
    }
}
