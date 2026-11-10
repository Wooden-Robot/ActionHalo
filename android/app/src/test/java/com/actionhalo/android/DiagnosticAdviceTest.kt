package com.actionhalo.android

import org.junit.Assert.*
import org.junit.Test

class DiagnosticAdviceTest {
    private fun advice(requested: Boolean = true, authorized: Boolean = true, connected: Boolean = true,
        paused: Boolean = false, hasActions: Boolean = true, result: SelectionDiagnostics.Result = SelectionDiagnostics.Result.WAITING,
        stage: TelegramCopyDiagnostics.Stage = TelegramCopyDiagnostics.Stage.WAITING, latest: Boolean = false) =
        DiagnosticAdvice.resolve(requested, authorized, connected, paused, hasActions, result, stage, latest)

    @Test fun currentServiceHealthTakesPrecedenceOverAnOlderSuccessfulAction() {
        assertEquals(DiagnosticAdvice.Action.AUTHORIZE, advice(authorized = false,
            stage = TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED, latest = true).action)
        assertEquals(DiagnosticAdvice.Action.BACKGROUND, advice(connected = false).action)
        assertEquals(DiagnosticAdvice.Action.RESUME, advice(paused = true).action)
        assertEquals(DiagnosticAdvice.Action.TRIGGERS, advice(requested = false).action)
    }

    @Test fun appRulesAndProtectedSelectionsHaveSpecificRecoveryPaths() {
        assertEquals(DiagnosticAdvice.Action.RULES, advice(result = SelectionDiagnostics.Result.APP_DISABLED).action)
        assertEquals(DiagnosticAdvice.Action.RULES, advice(result = SelectionDiagnostics.Result.APP_PAUSED).action)
        assertEquals(R.string.advice_filtered_title, advice(result = SelectionDiagnostics.Result.FILTERED).title)
        assertEquals(R.string.advice_long_press_title, advice(result = SelectionDiagnostics.Result.LONG_PRESS_ONLY).title)
        assertEquals(DiagnosticAdvice.Action.ACTIONS, advice(hasActions = false).action)
        assertEquals("A source-specific empty list must lead to app rules", DiagnosticAdvice.Action.RULES,
            advice(result = SelectionDiagnostics.Result.NO_ACTIONS, hasActions = true).action)
    }

    @Test fun staleCopyFailureDoesNotOverrideANewerNativeSelection() {
        assertEquals(R.string.advice_long_press_title, advice(result = SelectionDiagnostics.Result.LONG_PRESS_ONLY,
            stage = TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED, latest = false).title)
        assertEquals(R.string.advice_reselect_title, advice(result = SelectionDiagnostics.Result.LONG_PRESS_ONLY,
            stage = TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED, latest = true).title)
        assertEquals(R.string.advice_focus_title, advice(stage = TelegramCopyDiagnostics.Stage.CLIP_UNAVAILABLE, latest = true).title)
    }
}
