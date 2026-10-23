package com.droidlink.app.screen

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.Log
import com.google.protobuf.ByteString
import droidlink.protocol.ScreenProto.AppInfo
import droidlink.protocol.ScreenProto.ListAppsResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * Manages querying installed Android applications and launching them via Intent.
 */
class AndroidAppManager(private val context: Context) {

    companion object {
        private const val TAG = "AndroidAppManager"
        private const val ICON_SIZE = 64
        @Volatile private var cachedAppsResponse: ListAppsResponse? = null
    }

    /**
     * Lists all launchable applications with their name, package, system flag, and icon.
     * Uses parallel coroutines and in-memory caching for instant retrieval.
     */
    suspend fun getInstalledApps(includeSystem: Boolean = true, forceRefresh: Boolean = false): ListAppsResponse = withContext(Dispatchers.IO) {
        if (!forceRefresh && cachedAppsResponse != null && cachedAppsResponse!!.appsCount > 0) {
            Log.d(TAG, "Returning cached ${cachedAppsResponse!!.appsCount} installed apps")
            return@withContext cachedAppsResponse!!
        }

        val pm = context.packageManager
        val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }

        val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
        Log.d(TAG, "Found ${resolveInfos.size} launchable activities. Processing in parallel...")

        val appList = coroutineScope {
            resolveInfos.map { resolveInfo ->
                async(Dispatchers.Default) {
                    try {
                        val appInfo = resolveInfo.activityInfo.applicationInfo
                        val isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                        if (!includeSystem && isSystem) {
                            return@async null
                        }

                        val packageName = resolveInfo.activityInfo.packageName
                        val appLabel = resolveInfo.loadLabel(pm).toString()
                        val iconDrawable = resolveInfo.loadIcon(pm)
                        val iconBytes = drawableToCompressedBytes(iconDrawable)

                        AppInfo.newBuilder()
                            .setPackageName(packageName)
                            .setAppName(appLabel)
                            .setIsSystem(isSystem)
                            .setVersionName("")
                            .apply {
                                if (iconBytes.isNotEmpty()) {
                                    setIconPng(ByteString.copyFrom(iconBytes))
                                }
                            }
                            .build()
                    } catch (e: Exception) {
                        null
                    }
                }
            }.mapNotNull { it.await() }
        }.sortedBy { it.appName.lowercase() }

        val response = ListAppsResponse.newBuilder()
            .addAllApps(appList)
            .build()

        cachedAppsResponse = response
        Log.i(TAG, "✅ Loaded and cached ${response.appsCount} apps successfully")
        response
    }

    /**
     * Launches the specified application into the foreground.
     */
    fun launchApp(packageName: String): Boolean {
        return try {
            val pm = context.packageManager
            val launchIntent = pm.getLaunchIntentForPackage(packageName)
            if (launchIntent != null) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                context.startActivity(launchIntent)
                Log.i(TAG, "🚀 Successfully launched app: $packageName")
                true
            } else {
                Log.w(TAG, "No launch intent found for package: $packageName")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch package $packageName", e)
            false
        }
    }

    private fun drawableToCompressedBytes(drawable: Drawable): ByteArray {
        return try {
            val bitmap = createBitmapFromDrawable(drawable)
            val stream = ByteArrayOutputStream()
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                bitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, 75, stream)
            } else {
                bitmap.compress(Bitmap.CompressFormat.JPEG, 75, stream)
            }
            stream.toByteArray()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to compress icon: ${e.message}")
            ByteArray(0)
        }
    }

    private fun createBitmapFromDrawable(drawable: Drawable): Bitmap {
        val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
