package com.chakra.comicreader.ui.reader

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** UI regression for the reader dead end: a failed page must offer a way forward and back. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class ErrorViewTest {
    @get:Rule val rule = createComposeRule()

    @Test fun showsMessageAndPageButtonsThatCallBack() {
        var prev = 0
        var next = 0
        rule.setContent {
            ErrorView("Failed to load page 3: boom", canNavigate = true, onPrev = { prev++ }, onNext = { next++ })
        }

        rule.onNodeWithText("Failed to load page 3: boom").assertIsDisplayed()
        rule.onNodeWithText("Next page").performClick()
        rule.onNodeWithText("Previous page").performClick()
        rule.onNodeWithText("Next page").performClick()

        assertEquals(2, next)
        assertEquals(1, prev)
    }

    @Test fun singlePageComicHasNothingToNavigateTo() {
        rule.setContent { ErrorView("Comic not found.", canNavigate = false, onPrev = {}, onNext = {}) }

        rule.onNodeWithText("Comic not found.").assertIsDisplayed()
        rule.onNodeWithText("Next page").assertDoesNotExist()
        rule.onNodeWithText("Previous page").assertDoesNotExist()
    }
}
