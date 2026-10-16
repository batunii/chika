package com.chakra.comicreader.ui.reader

import kotlin.test.Test
import kotlin.test.assertEquals

class ReaderNavigationTest {
    private val outro = ReaderNavigation.ENTER_AT_OUTRO

    @Test fun nextWalksSlotsThenTurnsToNextPageIntro() {
        // 3 panels: slots 0 intro, 1..3 panels, 4 outro
        assertEquals(NavStep(NavAction.SLOT, 2, 1), ReaderNavigation.next(0, 3, 2, 5))
        assertEquals(NavStep(NavAction.SLOT, 2, 4), ReaderNavigation.next(3, 3, 2, 5))
        assertEquals(NavStep(NavAction.PAGE, 3, 0), ReaderNavigation.next(4, 3, 2, 5))
    }

    @Test fun nextAtFinalOutroStays() {
        assertEquals(NavAction.STAY, ReaderNavigation.next(4, 3, 4, 5).action)
    }

    @Test fun previousWalksBackThenEntersPreviousPageAtItsOutro() {
        assertEquals(NavStep(NavAction.SLOT, 2, 0), ReaderNavigation.previous(1, 2))
        assertEquals(NavStep(NavAction.PAGE, 1, outro), ReaderNavigation.previous(0, 2))
    }

    @Test fun previousAtFirstIntroStays() {
        assertEquals(NavAction.STAY, ReaderNavigation.previous(0, 0).action)
    }

    @Test fun pageWithNoPanelsStillHasIntroAndOutro() {
        assertEquals(NavStep(NavAction.SLOT, 0, 1), ReaderNavigation.next(0, 0, 0, 2))
        assertEquals(NavStep(NavAction.PAGE, 1, 0), ReaderNavigation.next(1, 0, 0, 2))
    }

    @Test fun resolveSlotHandlesOutroSentinelAndClamps() {
        assertEquals(7, ReaderNavigation.resolveSlot(outro, 6))
        assertEquals(0, ReaderNavigation.resolveSlot(0, 6))
        assertEquals(7, ReaderNavigation.resolveSlot(99, 6))
        assertEquals(1, ReaderNavigation.resolveSlot(outro, 0))
    }
}
