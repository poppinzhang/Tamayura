package dev.tamayura.app

import android.content.Context
import android.content.res.Configuration
import android.os.LocaleList
import java.util.Locale

/**
 * Native text in the interface language chosen in Tamayura. Dart sends the
 * preference (`system`, `zh`, `ja` or `en`); `system` resolves as in Dart:
 * the first supported system language, otherwise English.
 */
internal object AppText {
    const val SYSTEM = "system"
    private val supported = listOf("zh", "ja", "en")
    private const val PREFERENCES = "tamayura-language"
    private const val KEY = "language"
    // The last localized context, keyed by application and locale.
    private var cached: Triple<Context, Locale, Context>? = null

    fun setLanguage(context: Context, language: String) {
        require(language == SYSTEM || language in supported) { "Unsupported language: $language" }
        check(preferences(context).edit().putString(KEY, language).commit()) {
            "Cannot save the interface language"
        }
    }

    fun language(context: Context): String =
        preferences(context).getString(KEY, SYSTEM)?.takeIf { it == SYSTEM || it in supported } ?: SYSTEM

    fun resolve(language: String, system: LocaleList): String {
        if (language in supported) return language
        for (index in 0 until system.size()) {
            val code = system[index].language
            if (code in supported) return code
        }
        return "en"
    }

    fun locale(context: Context): Locale = when (resolve(language(context), LocaleList.getDefault())) {
        "zh" -> Locale.SIMPLIFIED_CHINESE
        "ja" -> Locale.JAPANESE
        else -> Locale.ENGLISH
    }

    /** A context whose resources use the interface language. */
    @Synchronized fun localized(context: Context): Context {
        val application = context.applicationContext ?: context
        val locale = locale(application)
        cached?.let { (owner, cachedLocale, localized) ->
            if (owner === application && cachedLocale == locale) return localized
        }
        val configuration = Configuration(application.resources.configuration)
        configuration.setLocales(LocaleList(locale))
        return application.createConfigurationContext(configuration).also {
            cached = Triple(application, locale, it)
        }
    }

    fun get(context: Context, id: Int, vararg args: Any): String = localized(context).getString(id, *args)

    /** The user-facing text of [error]: its string resource, or its own message. */
    fun message(context: Context, error: Throwable): String? =
        (error as? LocalizedText)?.let { get(context, it.textId, *it.textArgs) } ?: error.message

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}

/**
 * A failure raised by Android-independent code. Its user-facing text is a
 * string resource resolved where the failure is reported; [Throwable.message]
 * stays a diagnostic for logs and JVM tests.
 */
internal interface LocalizedText {
    val textId: Int
    val textArgs: Array<out Any> get() = emptyArray()
}
