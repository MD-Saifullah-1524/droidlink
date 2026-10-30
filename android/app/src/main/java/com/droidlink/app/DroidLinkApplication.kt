package com.droidlink.app

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class DroidLinkApplication : Application() {
    
    override fun onCreate() {
        super.onCreate()
        
        // Start UDP beacon listener for wireless Mac discovery & remote wake-up
        com.droidlink.app.discovery.UdpBeaconListener.start(this)
    }
}
