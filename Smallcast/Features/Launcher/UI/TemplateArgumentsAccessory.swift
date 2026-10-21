import SwiftUI

/// The inline argument strip for a row whose values fill a `SnippetTemplateEngine` template.
@MainActor
enum TemplateArgumentsAccessory {
    /// Nil when the template asks for nothing. Drawing reads the template alone, never a context.
    static func make(
        template: String,
        entryID: String,
        symbol: String?,
        metrics: InterfaceMetrics,
        vm: PaletteState,
        focus: FocusState<String?>.Binding,
        placement: PaletteHeaderAccessory.Placement,
        readsAsSentence: Bool = false,
        onOpenOptions: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) -> PaletteHeaderAccessory? {
        // A prose template's own words go between the fields; a URL's would be query-string noise.
        let words = readsAsSentence ? SnippetTemplateEngine.connectingWords(in: template) : [:]
        let arguments = SnippetTemplateEngine.declaredArguments(in: template).map {
            InlineArgument(
                id: $0.name, title: $0.name, options: $0.options, isOptional: $0.isOptional,
                leadingText: words[$0.name])
        }
        guard !arguments.isEmpty else { return nil }

        let value = { (name: String) in binding(entryID: entryID, name: name, vm: vm) }
        return PaletteHeaderAccessory(
            width: InlineArgumentFields.totalWidth(
                for: arguments, hasIcon: symbol != nil, metrics: metrics),
            fieldNames: arguments.map(\.id),
            firstIncompleteField: arguments.first {
                !$0.isOptional && value($0.id).wrappedValue.isEmpty
            }?.id,
            optionsMenu: { id in
                guard let argument = arguments.first(where: { $0.id == id }),
                    !argument.options.isEmpty
                else { return nil }
                return menu(for: argument, value: value(id))
            },
            placement: placement,
            // Identity per row, so which fields were left unanswered resets on the next one.
            view: AnyView(
                InlineArgumentFields(
                    arguments: arguments, symbol: symbol, value: value, focused: focus,
                    openOptions: onOpenOptions, onSubmit: onSubmit
                )
                .id(entryID))
        )
    }

    /// The typed values for one row, stripped of blanks — what its funnel is handed.
    static func values(template: String, entryID: String, vm: PaletteState) -> [String: String] {
        var values: [String: String] = [:]
        for argument in SnippetTemplateEngine.declaredArguments(in: template) {
            let typed = vm.commandArguments[PaletteState.argumentKey(entryID, argument.name)] ?? ""
            if !typed.isEmpty { values[argument.name] = typed }
        }
        return values
    }

    private static func binding(entryID: String, name: String, vm: PaletteState) -> Binding<String> {
        let key = PaletteState.argumentKey(entryID, name)
        return Binding(get: { vm.commandArguments[key] ?? "" }, set: { vm.commandArguments[key] = $0 })
    }

    private static func menu(
        for argument: InlineArgument, value: Binding<String>
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            header: argument.title,
            items: argument.options.map { option in
                PopoverMenuItem(
                    title: option,
                    icon: value.wrappedValue == option ? .symbol("checkmark") : .blank
                ) {
                    value.wrappedValue = option
                }
            })
    }
}
