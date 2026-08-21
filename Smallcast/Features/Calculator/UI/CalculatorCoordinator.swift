import AppKit

/// Owns copying a calculation out: the inline card records history, a history row never re-records.
@MainActor
final class CalculatorCoordinator {
    private let calcHistory: CalculatorHistoryStore
    private let palette: PaletteState
    private let currencyRates: CurrencyRateStore
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs, for the one action here that can't be undone.
    private unowned let core: AppCore

    init(
        calcHistory: CalculatorHistoryStore, palette: PaletteState,
        currencyRates: CurrencyRateStore, paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.calcHistory = calcHistory
        self.palette = palette
        self.currencyRates = currencyRates
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Remember whatever the search currently evaluates to, without copying it — a calculation you
    /// only looked at is still one you did.
    ///
    /// Called at exactly the moments a query stops being edited: Escape clearing the field, and every
    /// `PaletteState.prepare` (the pop-to-root reset, a mode switch, a fresh summon). Editing never
    /// commits, so "1+2" grown into "1+21" only records the latter, and re-opening within the grace
    /// period to keep typing replaces it rather than saving it. Re-committing the same thing is
    /// harmless — `CalculatorHistoryStore.record` drops a repeat of the newest entry.
    func commitCalculation() {
        // Only the two screens that actually show the answer card: inside a running command the
        // search bar belongs to the extension, and "1+2" typed into its filter is not a calculation.
        guard palette.mode == .launcher || palette.mode == .calculatorHistory,
            !palette.query.trimmingCharacters(in: .whitespaces).isEmpty,
            let result = CalcMemo.evaluate(palette.query, rates: currencyRates.rates),
            case .value(let display, _) = result.payload
        else { return }
        calcHistory.record(expression: result.expression, result: display)
    }

    /// Escape with text: remember any calculation it produced, then empty the field. The palette
    /// stays open, so this is the one discard that doesn't go through `prepare`.
    func clearSearch() {
        commitCalculation()
        palette.query = ""
    }

    /// Both the ⌃⇧X chord and the menu row land here, so neither can skip the confirmation.
    func deleteAllHistory() async {
        guard
            await core.confirm(
                title: "Clear calculation history?",
                message: "Every past calculation goes. This can't be undone.",
                symbol: PaletteMode.calculatorHistory.systemImage, confirmTitle: "Clear History")
        else { return }
        calcHistory.clearAll()
    }

    /// Enter on the inline calculator card: copy the answer, remember the calculation, dismiss.
    func copyCalculatorResult(_ result: CalcResult) {
        guard case .value(let display, let copyText) = result.payload else { return }
        calcHistory.record(expression: result.expression, result: display)
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(copyText)
    }

    /// Enter on a Calculator History row: re-copy the stored answer (no re-record).
    func copyHistoryEntry(_ entry: CalcHistoryEntry) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(entry.result.replacingOccurrences(of: ",", with: ""))
    }

    func copyHistoryExpression(_ entry: CalcHistoryEntry) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(entry.expression)
    }
}
