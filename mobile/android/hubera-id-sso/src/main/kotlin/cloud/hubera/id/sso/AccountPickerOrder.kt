package cloud.hubera.id.sso

/**
 * Le compte déjà porté par Music ou Hubera ID reste le premier.
 * Un compte ajouté ensuite ne le remplace pas et ne le retire pas.
 */
object AccountPickerOrder {
    fun isDeviceCarrier(sourcePackage: String?): Boolean {
        val p = sourcePackage?.trim()?.lowercase().orEmpty()
        if (p.isEmpty()) return false
        return p == "cloud.hubera.id" ||
            p == "ovh.delhomme.ytmusic" ||
            p.startsWith("cloud.hubera.music")
    }

    fun choosePin(
        accounts: List<HuberaIdAccount>,
        copies: List<HuberaIdAccount>,
        existingPin: String?,
    ): String? {
        val present = accounts.map { it.email.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
        val pin = existingPin?.trim()?.lowercase().orEmpty()
        if (pin.isNotEmpty() && present.contains(pin)) return pin
        val carrierEmails = copies
            .filter { isDeviceCarrier(it.sourcePackage) }
            .map { it.email.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()
        val pool = accounts
            .filter { carrierEmails.contains(it.email.trim().lowercase()) }
            .ifEmpty { accounts }
        return pool.minWithOrNull(
            compareBy<HuberaIdAccount> { if (it.updatedAt <= 0L) Long.MAX_VALUE else it.updatedAt }
                .thenBy { it.email.lowercase() },
        )?.email?.trim()?.lowercase()?.ifEmpty { null }
    }

    fun placeFirst(accounts: List<HuberaIdAccount>, pin: String?): List<HuberaIdAccount> {
        val key = pin?.trim()?.lowercase().orEmpty()
        if (key.isEmpty() || accounts.size < 2) return accounts
        val first = accounts.filter { it.email.equals(key, ignoreCase = true) }
        if (first.isEmpty()) return accounts
        return first + accounts.filter { !it.email.equals(key, ignoreCase = true) }
    }
}
