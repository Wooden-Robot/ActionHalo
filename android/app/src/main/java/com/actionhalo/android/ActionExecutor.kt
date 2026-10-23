package com.actionhalo.android

import android.app.Activity
import android.app.AppOpsManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast

object ActionExecutor {
    fun execute(context: Context, action: HaloAction, text: String): Boolean =
        execute(context, action, text, { Toast.makeText(context, it, Toast.LENGTH_LONG).show() })

    /** Only a user-selected action calls this method; no text is sent in the background. */
    fun execute(context: Context, action: HaloAction, text: String, onError: (Int) -> Unit,
        sourcePackage: String? = null): Boolean {
        fun fail(message: Int): Boolean { onError(message); return false }
        if (!IncomingText.isUsable(text)) return fail(if (text.length > IncomingText.MAX_LENGTH)
            R.string.text_too_long else R.string.action_no_text)
        if (!ActionStore(context).isAllowedInApp(action.id, sourcePackage)) return fail(R.string.action_scope_blocked)
        return try {
            when (action.type) {
                ActionType.COPY -> {
                    // ClipboardService silently ignores writes denied by AppOps.
                    @Suppress("DEPRECATION")
                    val mode = context.getSystemService(AppOpsManager::class.java)
                        .noteOpNoThrow("android:write_clipboard", android.os.Process.myUid(), context.packageName)
                    if (mode != AppOpsManager.MODE_ALLOWED) return fail(R.string.action_not_allowed)
                    context.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("ActionHalo", text))
                    Toast.makeText(context, R.string.action_copied, Toast.LENGTH_SHORT).show()
                }
                ActionType.SHARE -> launch(context, Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                }, context.getString(R.string.action_share)))
                ActionType.EDIT_TEXT -> launch(context, Intent(context, EditTextActivity::class.java)
                    .putExtra(HaloActivity.EXTRA_DEMO_TEXT, text)
                    .putExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE, sourcePackage))
                else -> {
                    val web = webUrl(action, text)
                    if (action.type == ActionType.OPEN_URL && web == null) return fail(R.string.action_invalid_url)
                    if (action.type == ActionType.URL && web == null) return fail(R.string.action_invalid_template)
                    val route = ActionDestinations(context).route(action.id)
                    val targetPackage = route?.takeIf { it.startsWith("package:") }?.removePrefix("package:")
                    val targetUri = when {
                        targetPackage == DoubanSearch.PACKAGE_NAME && action.type == ActionType.DOUBAN_SEARCH -> DoubanSearch.appUri(text)
                        targetPackage in TelegramSearch.packages && action.type == ActionType.TELEGRAM_SEARCH -> TelegramSearch.appUri(text)
                        else -> web
                    }
                    if (targetPackage != null && targetUri != null && tryLaunch(context,
                            Intent(Intent.ACTION_VIEW, Uri.parse(targetUri)).setPackage(targetPackage))) return true
                    if (route != null && web == null) return fail(R.string.action_telegram_unavailable)
                    // A missing preferred app can still use the exact same web destination.
                    if (route != null && web != null) {
                        launch(context, Intent(Intent.ACTION_VIEW, Uri.parse(web)))
                        if (targetPackage != null) Toast.makeText(context, R.string.destination_fallback, Toast.LENGTH_SHORT).show()
                    } else when (action.type) {
                        ActionType.DOUBAN_SEARCH -> {
                            if (!tryLaunch(context, Intent(Intent.ACTION_VIEW, Uri.parse(DoubanSearch.appUri(text)))
                                    .setPackage(DoubanSearch.PACKAGE_NAME))) {
                                launch(context, Intent(Intent.ACTION_VIEW, Uri.parse(web)))
                                Toast.makeText(context, R.string.action_douban_web_fallback, Toast.LENGTH_SHORT).show()
                            }
                        }
                        ActionType.TELEGRAM_SEARCH -> {
                            if (TelegramSearch.packages.none { pkg -> tryLaunch(context,
                                    Intent(Intent.ACTION_VIEW, Uri.parse(TelegramSearch.appUri(text))).setPackage(pkg)) })
                                return fail(R.string.action_telegram_unavailable)
                        }
                        else -> launch(context, Intent(Intent.ACTION_VIEW, Uri.parse(requireNotNull(web))))
                    }
                }
            }
            true
        } catch (_: ActivityNotFoundException) { fail(R.string.action_no_app) }
        catch (_: SecurityException) { fail(R.string.action_not_allowed) }
    }

    internal fun webUrl(action: HaloAction, text: String): String? = when (action.type) {
        ActionType.URL -> action.template?.let { ActionUrls.build(it, text) }
        ActionType.OPEN_URL -> ActionUrls.normalizeOpenUrl(text)
        ActionType.DOUBAN_SEARCH, ActionType.DOUBAN_BOOK_SEARCH, ActionType.DOUBAN_MOVIE_SEARCH -> DoubanSearch.webUrl(text, action.type)
        else -> null
    }

    private fun tryLaunch(context: Context, intent: Intent): Boolean = try {
        launch(context, intent); true
    } catch (_: ActivityNotFoundException) { false } catch (_: SecurityException) { false }

    private fun launch(context: Context, intent: Intent) {
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
