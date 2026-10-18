package dev.tamayura.app

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.LocaleList
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class AppTextTest {
    private lateinit var application: Application
    private val systemLocales = LocaleList.getDefault()

    @Before fun setUp() {
        application = RuntimeEnvironment.getApplication()
        AppText.setLanguage(application, AppText.SYSTEM)
    }

    @After fun tearDown() { LocaleList.setDefault(systemLocales) }

    @Test fun systemPreferenceUsesTheFirstSupportedLanguageLikeDart() {
        fun resolve(tags: String) = AppText.resolve(AppText.SYSTEM, LocaleList.forLanguageTags(tags))
        assertEquals("zh", resolve("zh-CN"))
        assertEquals("zh", resolve("zh-Hant-TW,en-US"))
        assertEquals("ja", resolve("ja-JP"))
        assertEquals("ja", resolve("fr-FR,ja-JP,en-US"))
        assertEquals("en", resolve("en-GB"))
        assertEquals("en", resolve("fr-FR,de-DE"))
        assertEquals("en", AppText.resolve(AppText.SYSTEM, LocaleList.getEmptyLocaleList()))
        assertEquals("ja", AppText.resolve("ja", LocaleList.forLanguageTags("zh-CN")))
    }

    @Test fun savedLanguagesSelectTheirResources() {
        assertEquals(AppText.SYSTEM, AppText.language(application))
        for ((language, text) in listOf("zh" to "停止共享", "ja" to "共有を停止", "en" to "Stop sharing")) {
            AppText.setLanguage(application, language)
            assertEquals(language, AppText.language(application))
            assertEquals(text, AppText.get(application, R.string.sharing_notification_stop))
        }
        AppText.setLanguage(application, "ja")
        assertEquals("ローカルネットワークの検出に失敗しました (register: 3)。手動で接続できます",
            AppText.get(application, R.string.discovery_failed, "register", 3))
    }

    @Test fun followingTheSystemUsesItsCurrentLanguages() {
        LocaleList.setDefault(LocaleList.forLanguageTags("fr-FR,ja-JP"))
        assertEquals("共有を停止", AppText.get(application, R.string.sharing_notification_stop))
        LocaleList.setDefault(LocaleList.forLanguageTags("de-DE"))
        assertEquals("Stop sharing", AppText.get(application, R.string.sharing_notification_stop))
        LocaleList.setDefault(LocaleList.forLanguageTags("zh-Hant-HK"))
        assertEquals("停止共享", AppText.get(application, R.string.sharing_notification_stop))
    }

    @Test fun unsupportedPreferencesAreRejectedAndIgnored() {
        assertThrows(IllegalArgumentException::class.java) { AppText.setLanguage(application, "fr") }
        application.getSharedPreferences("tamayura-language", 0).edit().putString("language", "fr").commit()
        assertEquals(AppText.SYSTEM, AppText.language(application))
    }

    @Test fun androidIndependentFailuresAreWordedWhenReported() {
        AppText.setLanguage(application, "en")
        assertEquals("This folder is already shared, or it contains or is inside a shared folder.",
            AppText.message(application, DirectoryOverlapException()))
        assertEquals("Invalid download task ID",
            AppText.message(application, assertThrows(IllegalArgumentException::class.java) {
                TransferPolicy.requireTaskId("")
            }))
        AppText.setLanguage(application, "ja")
        assertEquals("共有フォルダーが変更されました。もう一度スキャンしてください",
            AppText.message(application, CatalogChangedException()))
        assertEquals("plain", AppText.message(application, IllegalStateException("plain")))
    }

    @Test fun platformLanguageChangesRenameExistingChannels() {
        val notifications = application.getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(
            TransferScheduler.CHANNEL, "old", NotificationManager.IMPORTANCE_LOW))
        val result = Result()
        AndroidRuntime.get(application).handleMethod(
            MethodCall("setLanguage", mapOf("language" to "ja")), result)
        assertEquals(1, result.replies)
        assertNull(result.errorCode)
        assertEquals("ja", AppText.language(application))
        assertEquals("メディアのダウンロード",
            notifications.getNotificationChannel(TransferScheduler.CHANNEL).name)
        // Channels the user has never seen are not created by a language change.
        assertNull(notifications.getNotificationChannel(BackgroundSharingService.CHANNEL))

        val invalid = Result()
        AndroidRuntime.get(application).handleMethod(
            MethodCall("setLanguage", mapOf("language" to "fr")), invalid)
        assertEquals("INVALID_ARGUMENT", invalid.errorCode)
        assertEquals("ja", AppText.language(application))
    }

    private class Result : MethodChannel.Result {
        var replies = 0
        var errorCode: String? = null
        override fun success(result: Any?) { replies += 1 }
        override fun error(code: String, message: String?, details: Any?) { replies += 1; errorCode = code }
        override fun notImplemented() { replies += 1; errorCode = "NOT_IMPLEMENTED" }
    }
}
