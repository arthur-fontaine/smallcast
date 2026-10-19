import SwiftUI

/// The inline argument strip, as a `PaletteHeaderAccessory` the palette renders without reading.
@MainActor
enum QuicklinkArgumentsAccessory {
    /// Nil when the selected quicklink asks for nothing, which is every link without a placeholder.
    static func make(
        quicklink: Quicklink?,
        core: AppCore,
        vm: PaletteState,
        focus: FocusState<String?>.Binding,
        placement: PaletteHeaderAccessory.Placement,
        onOpenOptions: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) -> PaletteHeaderAccessory? {
        guard let quicklink else { return nil }
        // Its own screen already shows the row the fields belong to, so the glyph would repeat it.
        return TemplateArgumentsAccessory.make(
            template: quicklink.link, entryID: quicklink.entryID,
            symbol: placement == .afterQuery ? quicklink.symbol : nil,
            metrics: core.settings.interfaceSize.metrics, vm: vm, focus: focus,
            placement: placement, onOpenOptions: onOpenOptions, onSubmit: onSubmit)
    }

    /// The typed values for one quicklink, stripped of blanks — what the open funnel is handed.
    static func values(for quicklink: Quicklink, vm: PaletteState) -> [String: String] {
        TemplateArgumentsAccessory.values(template: quicklink.link, entryID: quicklink.entryID, vm: vm)
    }
}
