package com.actionhalo.android

internal data class AndroidVersion private constructor(val parts: List<Long>) : Comparable<AndroidVersion> {
    override fun compareTo(other: AndroidVersion): Int {
        parts.zip(other.parts).forEach { (left, right) ->
            if (left != right) return left.compareTo(right)
        }
        return 0
    }

    companion object {
        fun parse(value: String): AndroidVersion? {
            if (!value.matches(Regex("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)"))) return null
            val parts = value.split('.').map { it.toLongOrNull() ?: return null }
            return AndroidVersion(parts)
        }
    }
}
