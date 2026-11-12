package br.com.milkwork.mw_printer

import android.bluetooth.BluetoothClass
import java.util.Locale
import java.util.UUID

/** UUIDs e heurísticas conhecidas de impressoras térmicas. */
object PrinterProfiles {

    /** Serial Port Profile (Bluetooth Clássico). */
    val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private fun u16(short: String): UUID =
        UUID.fromString("0000$short-0000-1000-8000-00805f9b34fb")

    /**
     * Pares (serviço -> característica de escrita) em ordem de preferência.
     * Cobre Knup, Goojprt, MPT, Xprinter, Rongta, HPRT, Zjiang, Leopardo,
     * Datecs (modo BLE), "cat printers" e módulos ISSC/Microchip/HM-10.
     */
    val BLE_WRITE_PROFILES: List<Pair<UUID, UUID>> = listOf(
        u16("18f0") to u16("2af1"),
        u16("ff00") to u16("ff02"),
        UUID.fromString("49535343-fe7d-4ae5-8fa9-9fafd205e455") to
                UUID.fromString("49535343-8841-43f4-a8d4-ecbe34729bb3"),
        UUID.fromString("e7810a71-73ae-499d-8c15-faa9aef0c3f2") to
                UUID.fromString("bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"),
        u16("ffe0") to u16("ffe1"),
        u16("fff0") to u16("fff2"),
        u16("ae30") to u16("ae01"),
        u16("ae00") to u16("ae01"),
        u16("fee7") to u16("fec7"),
        u16("ff00") to u16("ff01"),
    )

    val KNOWN_PRINTER_SERVICES: Set<UUID> = BLE_WRITE_PROFILES.map { it.first }.toSet()

    /** Serviços padrão que nunca são canal de impressão. */
    val IGNORED_SERVICES: Set<UUID> = setOf(
        u16("1800"), u16("1801"), u16("180a"), u16("180f"), u16("1805"),
    )

    private val NAME_HINTS = listOf(
        "knup", "kp-", "kp ", "kp1", "printer", "print", "pos", "mpt", "pt-", "pt2",
        "pt3", "mtp", "goojprt", "xprinter", "xp-", "rpp", "rongta", "hprt", "hm-",
        "zjiang", "zj-", "leopardo", "datecs", "dpp", "elgin", "bematech", "epson",
        "tm-", "sunmi", "spp", "thermal", "inner", "qs-", "p58", "p80", "58mm",
        "80mm", "jp-", "mht", "gp-", "gprinter", "iposprinter", "seypos", "sm-l",
        "woosim", "zebra", "zq5", "zq6", "cpcl", "m58", "m80", "ez-", "dl-", "pl58",
        "impressora",
    )

    fun nameLooksLikePrinter(name: String?): Boolean {
        if (name.isNullOrBlank()) return false
        val n = name.lowercase(Locale.ROOT)
        return NAME_HINTS.any { n.contains(it) }
    }

    @Suppress("DEPRECATION")
    fun classLooksLikePrinter(btClass: BluetoothClass?): Boolean {
        if (btClass == null) return false
        // Major class IMAGING (0x0600). Bit 0x80 do minor = impressora.
        return btClass.majorDeviceClass == BluetoothClass.Device.Major.IMAGING
    }

    /** Classes que certamente NÃO são impressoras (fones, celulares, PCs, TVs...). */
    @Suppress("DEPRECATION")
    fun classIsCertainlyNotPrinter(btClass: BluetoothClass?): Boolean {
        if (btClass == null) return false
        return when (btClass.majorDeviceClass) {
            BluetoothClass.Device.Major.AUDIO_VIDEO,
            BluetoothClass.Device.Major.PHONE,
            BluetoothClass.Device.Major.COMPUTER,
            BluetoothClass.Device.Major.WEARABLE,
            BluetoothClass.Device.Major.HEALTH,
            BluetoothClass.Device.Major.TOY -> true
            else -> false
        }
    }
}
