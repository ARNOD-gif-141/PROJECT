package com.arnod.arno_link

import android.app.Notification
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel

// Listens to the phone's notifications (this is what makes "Arno Link" appear in Notification access).
class NotifService : NotificationListenerService() {
    companion object {
        @Volatile var sink: EventChannel.EventSink? = null
        val handler = Handler(Looper.getMainLooper())
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) { push(sbn, false) }
    override fun onNotificationRemoved(sbn: StatusBarNotification) { push(sbn, true) }

    private fun push(sbn: StatusBarNotification, removed: Boolean) {
        val n = sbn.notification ?: return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val ex = n.extras
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        val m = hashMapOf<String, Any>("pkg" to sbn.packageName, "title" to title, "text" to text, "removed" to removed)
        handler.post { sink?.success(m) }
    }
}
