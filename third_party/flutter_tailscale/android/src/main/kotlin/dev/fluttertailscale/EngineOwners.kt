package dev.fluttertailscale

/** Linearizes an Engine's native initialization against Engine destruction. */
internal class EngineOwners {
    private var attached = true
    private val owners = mutableSetOf<String>()

    @Synchronized fun isAttached(): Boolean = attached

    /** False means the caller must immediately dispose the just-created owner. */
    @Synchronized fun register(owner: String): Boolean {
        if (!attached) return false
        owners.add(owner)
        return true
    }

    @Synchronized fun unregister(owner: String) { owners.remove(owner) }

    @Synchronized fun detach(): List<String> {
        attached = false
        return owners.toList().also { owners.clear() }
    }
}
