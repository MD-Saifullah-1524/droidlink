package com.droidlink.app.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.util.Log
import com.droidlink.app.service.DroidLinkService

class AoaUsbReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "AoaUsbReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.d(TAG, "onReceive action: $action")

        when (action) {
            UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> {
                val accessory = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                }
                Log.i(TAG, "🔌 USB Accessory Attached: ${accessory?.manufacturer} - ${accessory?.model}")
                if (accessory != null) {
                    DroidLinkService.handleUsbAccessoryAttached(context, accessory)
                }
            }
            UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                Log.i(TAG, "🔌 USB Accessory Detached")
                DroidLinkService.handleUsbAccessoryDetached(context)
            }
        }
    }
}
