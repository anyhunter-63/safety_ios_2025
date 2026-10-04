package com.civil.safetyapp

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

class LocationService : Service() {

    private lateinit var fusedClient: FusedLocationProviderClient
    private lateinit var callback: LocationCallback

    @SuppressLint("MissingPermission")
    override fun onCreate() {
        super.onCreate()

        startForegroundNotification()

        fusedClient = LocationServices.getFusedLocationProviderClient(this)

        /*
         * 30초마다 고정밀 위치 요청
         *
         * 위치 권한 체크는 Flutter 쪽에서 스캔 시작 전에 처리하고 있음.
         * 이 서비스는 권한이 확보된 상태에서 시작된다고 가정한다.
         */
        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            30_000L
        )
            // 필요하면 최소 이동거리 조건 사용 가능
            // .setMinUpdateDistanceMeters(5f)
            .setWaitForAccurateLocation(false)
            .build()

        callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                super.onLocationResult(result)

                for (location: Location in result.locations) {
                    sendLocationToFlutter(location)
                }
            }
        }

        fusedClient.requestLocationUpdates(
            request,
            callback,
            mainLooper
        )
    }

    private fun sendLocationToFlutter(location: Location) {
        val data = hashMapOf(
            "lat" to location.latitude,
            "lng" to location.longitude,
            "time" to location.time
        )

        /*
         * Flutter 쪽 EventChannel 스트림으로만 위치 전달.
         *
         * 중요:
         * 여기서 서버로 직접 전송하지 않는다.
         * 서버 전송은 Flutter의 _processSafety()에서만 처리한다.
         *
         * 이전 코드에서 sendLocationToServer(location)를 호출하면서
         * android.os.Build.ID 값이 deviceId로 전송되어
         * BP4A.251205.006 같은 bad_device_id 로그가 발생했다.
         */
        BackgroundChannel.sink?.success(data)
    }

    private fun startForegroundNotification() {
        val channelId = "safety_location"
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Safety Location Service",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        val notification: Notification =
            NotificationCompat.Builder(this, channelId)
                .setContentTitle("안전 위치 서비스 작동 중")
                .setContentText("위치 정보를 주기적으로 확인합니다.")
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setOngoing(true)
                .build()

        startForeground(1, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        /*
         * ForegroundService 유지.
         * 서버 전송은 하지 않고, 위치는 EventChannel을 통해 Flutter로 전달한다.
         */
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()

        if (::fusedClient.isInitialized && ::callback.isInitialized) {
            fusedClient.removeLocationUpdates(callback)
        }
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
}