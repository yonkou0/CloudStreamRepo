package com.laddu100

import android.content.Context
import androidx.appcompat.app.AppCompatActivity
import com.lagradost.cloudstream3.CommonActivity.activity
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.plugins.CloudstreamPlugin

@CloudstreamPlugin
class LIVETVPlugin : Plugin() {

    private var sharedPref = activity?.getSharedPreferences("LIVETV", Context.MODE_PRIVATE)

    // Cached provider list. Deliberately NOT fetched inside load(): Plugin.load()
    // runs on the main thread, and fetching here blocked the UI (ANR risk).
    // Providers are loaded lazily on first use instead.
    @Volatile
    private var iptvProviders: List<Map<String, Any>> = emptyList()

    private fun registerProviders(providers: List<Map<String, Any>>) {
        val providerSettings = providers.mapNotNull { p ->
            val title = p["title"] as? String ?: return@mapNotNull null
            title to (sharedPref?.getBoolean(title, false) ?: false)
        }.toMap()

        providers
            .filter { p ->
                val title = p["title"] as? String
                title != null && providerSettings[title] == true
            }
            .forEach { p ->
                val title = p["title"] as String
                val catLink = p["catLink"] as String
                val type = p["type"] as? String ?: "custom"
                val displayTitle = title
                if (type == "custom") {
                    registerMainAPI(LIVETVLiveEventsProvider(displayTitle, catLink))
                } else {
                    registerMainAPI(LIVETV(displayTitle, catLink))
                }
            }
    }

    override fun load(context: Context) {
        LIVETV.context = context
        LIVETVLiveEventsProvider.context = context

        if (sharedPref == null) {
            sharedPref = activity?.getSharedPreferences("LIVETV", Context.MODE_PRIVATE)
        }

        // Always available so live events work immediately.
        registerMainAPI(LIVETVLiveEventsProvider())

        val act = context as AppCompatActivity
        openSettings = { _ ->
            // Settings UI is opened from the main thread, but it needs the
            // provider list to render. Keep this off the critical path by
            // loading synchronously only here (user-initiated, small payload)
            // rather than during plugin load.
            val currentProviders = iptvProviders.ifEmpty {
                kotlinx.coroutines.runBlocking { LIVETVProviderManager.fetchProviders() }
                    .also { iptvProviders = it }
            }
            LIVETVSettings(
                this,
                sharedPref,
                currentProviders.mapNotNull { it["title"] as? String }
            ).show(act.supportFragmentManager, "LIVETVSettings")
        }
    }

    /**
     * Fetches the provider list off the main thread and registers the
     * user-enabled providers. Safe to call repeatedly; only the first call
     * that finds an empty cache performs a network fetch.
     */
    suspend fun ensureProvidersLoaded() {
        if (iptvProviders.isNotEmpty()) return
        val fetched = LIVETVProviderManager.fetchProviders()
        if (fetched.isNotEmpty()) {
            iptvProviders = fetched
            registerProviders(fetched)
        }
    }

    fun cachedProviders(): List<Map<String, Any>> = iptvProviders
}

