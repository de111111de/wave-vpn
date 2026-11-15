package com.wave.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import androidx.core.app.NotificationCompat
import io.nekohasekai.libbox.BoxService
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface
import java.net.NetworkInterface as JNetworkInterface

/**
 * Real VPN service: libbox (sing-box core, pinned to the version built in CI) owns the TUN fd,
 * every outbound socket of the core is protect()-ed, traffic is streamed from clash_api.
 */
class WaveVpnService : VpnService(), PlatformInterface {
    companion object {
        const val ACTION_START = "com.wave.vpn.START"
        const val ACTION_STOP = "com.wave.vpn.STOP"
        const val EXTRA_CONFIG_PATH = "config_path"
        const val EXTRA_API_PORT = "api_port"
        const val EXTRA_SECRET = "secret"
        private const val CHANNEL_ID = "wave_vpn"
        private const val NOTIF_ID = 7
        private val libboxReady = AtomicBoolean(false)
    }

    private val worker = Executors.newSingleThreadExecutor()
    private var box: BoxService? = null
    private var tun: ParcelFileDescriptor? = null
    @Volatile private var trafficRun = false
    private var netCb: ConnectivityManager.NetworkCallback? = null
    private val cm by lazy { getSystemService(ConnectivityManager::class.java) }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                goForeground()
                val path = intent.getStringExtra(EXTRA_CONFIG_PATH)
                val port = intent.getIntExtra(EXTRA_API_PORT, 19090)
                val secret = intent.getStringExtra(EXTRA_SECRET) ?: ""
                worker.execute { startCore(path, port, secret) }
            }
            ACTION_STOP -> worker.execute {
                stopCore()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        worker.execute {
            stopCore()
            stopSelf()
        }
    }

    override fun onDestroy() {
        trafficRun = false
        try { box?.close() } catch (_: Throwable) {}
        closeTun()
        worker.shutdown()
        super.onDestroy()
    }

    // ───────── lifecycle ─────────

    private fun ensureSetup() {
        if (!libboxReady.compareAndSet(false, true)) return
        val base = File(filesDir, "sing-box")
        val work = File(base, "work")
        val tmp = File(cacheDir, "sing-box")
        work.mkdirs(); tmp.mkdirs()
        Libbox.setup(SetupOptions().also {
            it.basePath = base.path
            it.workingPath = work.path
            it.tempPath = tmp.path
        })
    }

    private fun startCore(configPath: String?, apiPort: Int, secret: String) {
        try {
            VpnBridge.emitState("connecting", null)
            if (box != null) stopCoreQuiet()
            val f = File(configPath ?: throw IllegalStateException("config path missing"))
            val config = f.readText()
            f.delete() // holds node credentials, no reason to keep it on disk
            ensureSetup()
            Libbox.checkConfig(config)
            val svc = Libbox.newService(config, this)
            svc.start()
            box = svc
            VpnBridge.emitState("connected", null)
            startTraffic(apiPort, secret)
        } catch (t: Throwable) {
            VpnBridge.log("start failed: $t")
            try { box?.close() } catch (_: Throwable) {}
            box = null
            closeTun()
            VpnBridge.emitState("error", t.message ?: t.toString())
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun stopCoreQuiet() {
        trafficRun = false
        try { box?.close() } catch (t: Throwable) { VpnBridge.log("close: $t") }
        box = null
        closeTun()
    }

    private fun stopCore() {
        stopCoreQuiet()
        VpnBridge.emitState("disconnected", null)
    }

    private fun closeTun() {
        try { tun?.close() } catch (_: Exception) {}
        tun = null
    }

    private fun goForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Wave VPN", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, WaveVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Wave")
            .setContentText("VPN активен")
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Отключить", stop)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    // ───────── traffic stream (clash_api /traffic: bytes per second) ─────────

    private fun startTraffic(port: Int, secret: String) {
        trafficRun = true
        Thread {
            var upT = 0L
            var dnT = 0L
            while (trafficRun) {
                var conn: HttpURLConnection? = null
                try {
                    conn = (URL("http://127.0.0.1:$port/traffic").openConnection() as HttpURLConnection).apply {
                        setRequestProperty("Authorization", "Bearer $secret")
                        connectTimeout = 2000
                        readTimeout = 0
                    }
                    conn.inputStream.bufferedReader().use { r ->
                        while (trafficRun) {
                            val line = r.readLine() ?: break
                            val j = JSONObject(line)
                            val up = j.optLong("up")
                            val dn = j.optLong("down")
                            upT += up; dnT += dn
                            VpnBridge.emitTraffic(up, dn, upT, dnT)
                        }
                    }
                } catch (_: Throwable) {
                    if (trafficRun) try { Thread.sleep(500) } catch (_: InterruptedException) {}
                } finally {
                    conn?.disconnect()
                }
            }
        }.apply { isDaemon = true; name = "wave-traffic" }.start()
    }

    // ───────── PlatformInterface ─────────

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")
        val b = Builder().setSession("Wave").setMetered(false)
        b.setMtu(options.mtu)
        val v4 = options.inet4Address
        while (v4.hasNext()) { val a = v4.next(); b.addAddress(a.address(), a.prefix()) }
        val v6 = options.inet6Address
        while (v6.hasNext()) { val a = v6.next(); b.addAddress(a.address(), a.prefix()) }

        if (options.autoRoute) {
            b.addDnsServer(options.dnsServerAddress.value)
            val r4 = options.inet4RouteAddress
            if (r4.hasNext()) {
                while (r4.hasNext()) { val a = r4.next(); b.addRoute(a.address(), a.prefix()) }
            } else if (options.inet4Address.hasNext()) {
                b.addRoute("0.0.0.0", 0)
            }
            val r6 = options.inet6RouteAddress
            if (r6.hasNext()) {
                while (r6.hasNext()) { val a = r6.next(); b.addRoute(a.address(), a.prefix()) }
            } else if (options.inet6Address.hasNext()) {
                b.addRoute("::", 0)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                val x4 = options.inet4RouteExcludeAddress
                while (x4.hasNext()) { val a = x4.next(); b.excludeRoute(IpPrefix(InetAddress.getByName(a.address()), a.prefix())) }
                val x6 = options.inet6RouteExcludeAddress
                while (x6.hasNext()) { val a = x6.next(); b.excludeRoute(IpPrefix(InetAddress.getByName(a.address()), a.prefix())) }
            }
            // Per-App split tunnelling: include_package / exclude_package from the sing-box tun inbound
            val inc = options.includePackage
            while (inc.hasNext()) { try { b.addAllowedApplication(inc.next()) } catch (_: Exception) {} }
            val exc = options.excludePackage
            while (exc.hasNext()) { try { b.addDisallowedApplication(exc.next()) } catch (_: Exception) {} }
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        b.setConfigureIntent(open)
        val pfd = b.establish() ?: error("android: VPN revoked or not prepared")
        tun = pfd
        return pfd.fd
    }

    override fun writeLog(message: String?) {
        VpnBridge.log(message)
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int,
    ): Int {
        val uid = cm.getConnectionOwnerUid(
            ipProtocol, InetSocketAddress(sourceAddress, sourcePort), InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        return uid
    }

    override fun packageNameByUid(uid: Int): String =
        packageManager.getPackagesForUid(uid)?.firstOrNull() ?: error("android: package not found")

    @Suppress("DEPRECATION")
    override fun uidByPackageName(packageName: String): Int = packageManager.getPackageUid(packageName, 0)

    override fun usePlatformDefaultInterfaceMonitor(): Boolean = true

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val handler = Handler(Looper.getMainLooper())
        val req = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()
        fun push(n: Network) {
            val lp: LinkProperties = cm.getLinkProperties(n) ?: return
            val name = lp.interfaceName ?: return
            val idx = JNetworkInterface.getByName(name)?.index ?: return
            listener.updateDefaultInterface(name, idx)
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = push(network)
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = push(network)
            override fun onLost(network: Network) = listener.updateDefaultInterface("", -1)
        }
        netCb = cb
        if (Build.VERSION.SDK_INT >= 31) {
            cm.registerBestMatchingNetworkCallback(req, cb, handler)
        } else {
            cm.requestNetwork(req, cb, handler)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        netCb?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        netCb = null
    }

    override fun usePlatformInterfaceGetter(): Boolean = true

    @Suppress("DEPRECATION")
    override fun getInterfaces(): NetworkInterfaceIterator {
        val nets = cm.allNetworks
        val ifs = JNetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
        val out = mutableListOf<BoxNetworkInterface>()
        for (n in nets) {
            val lp = cm.getLinkProperties(n) ?: continue
            val caps = cm.getNetworkCapabilities(n) ?: continue
            val name = lp.interfaceName ?: continue
            val ni = ifs.find { it.name == name } ?: continue
            out += BoxNetworkInterface().apply {
                this.name = name
                index = ni.index
                runCatching { mtu = ni.mtu }
                addresses = StringArray(ni.interfaceAddresses.map { "${it.address.hostAddress?.substringBefore('%')}/${it.networkPrefixLength}" })
                var fl = 0
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) fl = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (ni.isLoopback) fl = fl or OsConstants.IFF_LOOPBACK
                if (ni.isPointToPoint) fl = fl or OsConstants.IFF_POINTOPOINT
                if (ni.supportsMulticast()) fl = fl or OsConstants.IFF_MULTICAST
                flags = fl
            }
        }
        return InterfaceArray(out)
    }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun readWIFIState(): WIFIState? = null
    override fun clearDNSCache() {}
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification?) {}

    private class StringArray(private val list: List<String>) : StringIterator {
        private var i = 0
        override fun len(): Int = list.size
        override fun hasNext(): Boolean = i < list.size
        override fun next(): String = list[i++]
    }

    private class InterfaceArray(private val list: List<BoxNetworkInterface>) : NetworkInterfaceIterator {
        private var i = 0
        override fun hasNext(): Boolean = i < list.size
        override fun next(): BoxNetworkInterface = list[i++]
    }
}
