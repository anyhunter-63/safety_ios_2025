package com.civil.safetyapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

class SafeForegroundService : Service() {

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification()
    }

    private fun startForegroundNotification() {
        val channelId = "safety_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "안전지키미 실행중",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setContentTitle("안전지키미 실행 중")
                .setContentText("위험 감지 기능 활성화")
                .setOngoing(true)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .build()
        } else {
            Notification.Builder(this)
                .setContentTitle("안전지키미 실행 중")
                .setContentText("위험 감지 기능 활성화")
                .setOngoing(true)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .build()
        }

        startForeground(1, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
