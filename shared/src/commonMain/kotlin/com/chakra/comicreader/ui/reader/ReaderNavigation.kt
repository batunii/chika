package com.chakra.comicreader.ui.reader

/** What a navigation request should do. */
enum class NavAction { STAY, SLOT, PAGE }

/**
 * Result of [ReaderNavigation]: [SLOT] = move to [slot] on the current page; [PAGE] = turn to [page]
 * and land on [slot] (`0` = its intro, [ReaderNavigation.ENTER_AT_OUTRO] = its outro).
 */
data class NavStep(val action: NavAction, val page: Int, val slot: Int)

/**
 * The reader's slot arithmetic, shared by Android and iOS so the two state machines can't drift.
 * A page has slots `0` (whole-page intro), `1..panelCount` (panels in reading order) and
 * `panelCount + 1` (whole-page outro). Stepping past the outro turns to the next page's intro;
 * stepping back from an intro enters the previous page at its outro.
 */
object ReaderNavigation {
    /** Slot sentinel: "enter this page at its outro" (resolved once the page's panels are known). */
    const val ENTER_AT_OUTRO = -1

    fun next(slot: Int, panelCount: Int, page: Int, pageCount: Int): NavStep = when {
        slot < panelCount + 1 -> NavStep(NavAction.SLOT, page, slot + 1)
        page < pageCount - 1 -> NavStep(NavAction.PAGE, page + 1, 0)
        else -> NavStep(NavAction.STAY, page, slot) // already at the final outro
    }

    fun previous(slot: Int, page: Int): NavStep = when {
        slot > 0 -> NavStep(NavAction.SLOT, page, slot - 1)
        page > 0 -> NavStep(NavAction.PAGE, page - 1, ENTER_AT_OUTRO)
        else -> NavStep(NavAction.STAY, page, slot) // already at the very first intro
    }

    /** Resolves a target slot (possibly [ENTER_AT_OUTRO]) against a page's panel count. */
    fun resolveSlot(target: Int, panelCount: Int): Int =
        if (target == ENTER_AT_OUTRO) panelCount + 1 else target.coerceIn(0, panelCount + 1)
}
