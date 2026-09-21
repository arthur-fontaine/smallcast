#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/smallcast-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall the suite.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((SMALLCAST_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$SMALLCAST_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${SMALLCAST_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own script.
emit_db=0
DB="${TMPDIR:-/tmp}/smallcast-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run [slow] [-O] [index] <name> <source...> — queue the harness. `slow` dispatches it in the first
# wave; `index` claims editor flags for a harness that is compiled by hand rather than by the suite.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim every file under `Tests/`: the harness and any helper compiled beside it. A shipped
        # source stays unclaimed, because it would get this short command instead of the app's full
        # one and `.compile` is last-wins — but the app never compiles anything in `Tests/`.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Smallcast/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/EntryNaming.swift $L/LauncherOrder.swift
run slow -O corpus-test    $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift
run file-search-test       $L/SearchRelevance.swift \
                           Smallcast/Features/FileSearch/Model/*.swift
run file-search-session-test Smallcast/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Smallcast/Features/FileSearch/Model/*.swift \
                             Smallcast/Features/FileSearch/Service/*.swift
run menu-search-test       $L/SearchRelevance.swift \
                           Smallcast/Features/MenuSearch/Model/*.swift \
                           Smallcast/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Smallcast/Features/WindowSwitcher/Model/*.swift
run index file-search-performance Smallcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Smallcast/Features/FileSearch/Model/*.swift \
                           Smallcast/Features/FileSearch/Service/FileSearchService.swift
run ranking-test           $L/SearchRelevance.swift $L/LauncherRankingStore.swift
run launch-history-test    $L/LaunchHistoryStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Smallcast/Platform/AppDisplayName.swift \
                           Smallcast/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run calc-test              Smallcast/Features/Calculator/Model/*.swift
run index calc-performance Smallcast/Features/Calculator/Model/*.swift
run calendar-test          Smallcast/Features/Calendar/Model/*.swift
run clipboard-test         Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Smallcast/Features/Clipboard/Model/ColorValue.swift \
                           Smallcast/Features/Clipboard/Model/ColorFormat.swift \
                           Smallcast/Features/Clipboard/Model/ColorSpaces.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-search-test  Smallcast/Features/Clipboard/Model/*.swift $Q
run clipboard-text-test    Smallcast/Features/Clipboard/Model/*.swift $Q \
                           Smallcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Smallcast/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Smallcast/Features/Clipboard/Service/ClipboardTextWorker.swift
run pasteboard-test        Smallcast/Platform/PasteboardFiles.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Smallcast/Features/Clipboard/Model/ColorValue.swift \
                           Smallcast/Features/Clipboard/Model/ColorFormat.swift \
                           Smallcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Smallcast/Features/Clipboard/Service/ClipboardManager.swift \
                           Smallcast/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Smallcast/Platform/PasteboardFiles.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Smallcast/Features/Clipboard/Model/ColorValue.swift \
                           Smallcast/Features/Clipboard/Model/ColorFormat.swift \
                           Smallcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Smallcast/Features/Clipboard/Service/ClipboardManager.swift
run emoji-test             Smallcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Smallcast/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Smallcast/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Smallcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Smallcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Smallcast/Features/Emoji/Service/EmojiIndex.swift \
                           Smallcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Smallcast/Features/Launcher/Model/SearchRelevance.swift \
                           Smallcast/Platform/AppPaths.swift Smallcast/Platform/Memo.swift
run index emoji-search-performance \
                           Smallcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Smallcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Smallcast/Features/Emoji/Service/EmojiIndex.swift \
                           Smallcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Smallcast/Features/Launcher/Model/SearchRelevance.swift \
                           Smallcast/Platform/AppPaths.swift Smallcast/Platform/Memo.swift
run emo-test               Smallcast/Features/Emoji/Model/EmoTokenizer.swift \
                           Smallcast/Features/Emoji/Model/EmoModelInputs.swift \
                           Smallcast/Features/Emoji/Model/TypedTextPolicy.swift \
                           Smallcast/Features/Emoji/Service/EmoSuggester.swift \
                           Smallcast/Features/Emoji/Service/EmoModelStore.swift \
                           Smallcast/Platform/AppPaths.swift
run palette-selection-test Smallcast/Features/PaletteRowIndex.swift \
                           Smallcast/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           Smallcast/Features/Settings/AppAppearance.swift
run interface-size-test    Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           Smallcast/Features/Settings/InterfaceSize.swift \
                           Smallcast/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           Smallcast/Features/Settings/InterfaceSize.swift \
                           Smallcast/Palette/PalettePlacement.swift
run scroll-reveal-test     Smallcast/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Smallcast/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Smallcast/DesignSystem/Interaction/KeyboardFocus.swift
run ai-instructions-test   Smallcast/Features/AI/Model/AIInstructions.swift \
                           Smallcast/Features/AI/Model/AIPreamble.swift
run hover-arming-test      Smallcast/Palette/HoverArming.swift \
                           Smallcast/Palette/PaletteState.swift \
                           Smallcast/Palette/PaletteMode.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Smallcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Smallcast/Features/Clipboard/Model/ColorValue.swift \
                           Smallcast/Features/Clipboard/Model/ColorFormat.swift \
                           Smallcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-escape-test    Smallcast/Palette/PaletteMode.swift \
                           Smallcast/Palette/PaletteEscapeAction.swift \
                           Smallcast/Palette/CommandEscapeTap.swift \
                           Smallcast/Features/Settings/EscapeKeyBehavior.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Smallcast/Palette/PaletteState.swift \
                           Smallcast/Palette/PaletteMode.swift \
                           Smallcast/Palette/HoverArming.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Smallcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Smallcast/Features/Clipboard/Model/ColorValue.swift \
                           Smallcast/Features/Clipboard/Model/ColorFormat.swift \
                           Smallcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Smallcast/Palette/PaletteMode.swift \
                           Smallcast/Palette/PaletteFilterAction.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-shortcut-test  Smallcast/Palette/PaletteShortcut.swift
run palette-tab-test       Smallcast/Palette/PaletteMode.swift \
                           Smallcast/Palette/PaletteTabAction.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Smallcast/Features/Launcher/Model/Fallback.swift \
                           Smallcast/Features/Launcher/Model/CommandID.swift \
                           Smallcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Smallcast/Features/QuickActions/Model/QuickAction.swift \
                           Smallcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Smallcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/SystemActions/Model/SystemAction.swift \
                           Smallcast/Features/WindowManagement/Model/WindowCommand.swift
run hotkey-test            Smallcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Smallcast/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Smallcast/Features/HotKeys/Model/HyperKey.swift \
                           Smallcast/Platform/ASCIIKeyboardLayout.swift \
                           Smallcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Smallcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Smallcast/Features/QuickActions/Model/QuickAction.swift \
                           Smallcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Smallcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Smallcast/Features/Launcher/Model/CommandID.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/SystemActions/Model/SystemAction.swift \
                           Smallcast/Features/WindowManagement/Model/WindowCommand.swift
run callout-test           Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           Smallcast/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift
run entry-icon-test        Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift \
                           Smallcast/Platform/Images/FileIconStamp.swift
run ext-icon-test          Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift \
                           Smallcast/Platform/Compression/Zlib.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           Smallcast/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Smallcast/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Smallcast/Features/Extensions/Model/ExtensionManifest.swift \
                           Smallcast/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Smallcast/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Smallcast/Features/Extensions/Model/RenderNode.swift \
                           Smallcast/Features/Extensions/Service/ExtensionCatalog.swift \
                           Smallcast/Features/Extensions/Service/ExtensionFetcher.swift \
                           Smallcast/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Smallcast/Features/Extensions/Service/ExtensionOAuthKeychain.swift \
                           Smallcast/Features/Extensions/Service/ExtensionOAuthSession.swift \
                           Smallcast/Features/Extensions/Service/ExtensionRuntime.swift \
                           Smallcast/Features/Extensions/Service/ExtensionIconCache.swift \
                           Smallcast/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Smallcast/Features/Extensions/UI/ExtensionImage.swift
run system-action-test     Smallcast/Features/SystemActions/Model/SystemAction.swift
run volume-test            Smallcast/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Smallcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Smallcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Smallcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Smallcast/Features/WindowManagement/Model/WindowActionMemory.swift
run space-gesture-test     Smallcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Smallcast/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Smallcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Smallcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Smallcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Smallcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Smallcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Smallcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Smallcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Smallcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Smallcast/Features/WindowManagement/Model/WindowLayoutStore.swift
run custom-command-test    Smallcast/Platform/PseudoTerminal.swift \
                           Smallcast/Features/CustomCommands/Model/CustomCommand.swift \
                           Smallcast/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Smallcast/Features/CustomCommands/Service/ShellCommandRunner.swift \
                           Smallcast/Features/CustomCommands/Service/CustomCommandArgumentSession.swift
run uninstall-test         Smallcast/Features/Uninstall/Model/UninstallTarget.swift \
                           Smallcast/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Smallcast/Features/Uninstall/Model/UninstallRules.swift \
                           Smallcast/Features/Uninstall/Model/UninstallProtection.swift \
                           Smallcast/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Smallcast/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run slow snippets-test     Smallcast/Platform/NotificationToken.swift \
                           Smallcast/Platform/HealthTicker.swift \
                           Smallcast/Platform/KeystrokeTap.swift \
                           Smallcast/Platform/AccessibilityText.swift \
                           Smallcast/Features/Snippets/Model/*.swift \
                           Smallcast/Features/Snippets/Service/*.swift \
                           Smallcast/Features/TextInjection/Service/*.swift
run notes-test             Smallcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Smallcast/Features/Notes/Model/*.swift \
                           Smallcast/Features/Notes/Service/*.swift
run notes-editor-test      Smallcast/Platform/Signposts.swift \
                           Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           Smallcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Smallcast/Features/Notes/Model/NoteDocument.swift \
                           Smallcast/Features/Notes/UI/NoteTextView.swift \
                           Smallcast/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Smallcast/Features/Backup/Model/RaycastImportError.swift \
                           Smallcast/Features/Backup/Service/RaycastDecoder.swift \
                           Smallcast/Features/Backup/Service/Scrypt.swift \
                           Smallcast/Platform/Compression/Zlib.swift
run settings-backup-test   Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/Backup/Model/SettingsBackupCoverage.swift
run backup-archive-test    Smallcast/Platform/AppPaths.swift \
                           Smallcast/Features/Backup/Model/BackupArchive.swift \
                           Smallcast/Features/Backup/Model/BackupBundle.swift \
                           Smallcast/Features/Backup/Model/BackupCategory.swift \
                           Smallcast/Features/Backup/Model/BackupClipboardItem.swift \
                           Smallcast/Features/Backup/Model/BackupManifest.swift \
                           Smallcast/Features/Backup/Service/BackupStaging.swift
E=Smallcast/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-store-test         $E/Model/ExtensionRegistry.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Smallcast/Platform/Compression/Zlib.swift
run settings-history-test  Smallcast/Features/Settings/SettingsTab.swift \
                           Smallcast/Features/Settings/SettingsHistory.swift \
                           Smallcast/Features/Settings/SettingsAnchor.swift \
                           Smallcast/Features/Settings/SettingsNavigationState.swift \
                           Smallcast/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift
run updates-test           Smallcast/Features/Updates/Model/*.swift \
                           Smallcast/Features/Updates/Service/BundleSignature.swift
run support-test           Smallcast/Features/Support/Model/*.swift
run ai-provider-test       Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/AI/Model/*.swift \
                           Smallcast/Features/AI/Settings/AISettingsStore.swift
run ai-chat-test           Smallcast/Features/AI/Model/AIRequest.swift \
                           Smallcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Smallcast/Features/AI/Model/AIRetention.swift \
                           Smallcast/Features/AI/Model/AITool.swift \
                           Smallcast/Features/AI/Model/JSONValue.swift \
                           Smallcast/Features/AI/Model/ChatMessage.swift \
                           Smallcast/Features/AI/Model/ChatSession.swift \
                           Smallcast/Features/AI/Model/MarkdownBlock.swift \
                           Smallcast/Features/AI/Service/AIProvider.swift \
                           Smallcast/Features/AI/Service/ChatHistoryStore.swift \
                           Smallcast/Features/AI/Service/AIToolLoopProvider.swift \
                           Smallcast/Features/AI/UI/AIChatState.swift
run mcp-test               Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/AI/Model/AIConnection.swift \
                           Smallcast/Features/AI/Model/AppleIntelligence.swift \
                           Smallcast/Features/AI/Model/AITool.swift \
                           Smallcast/Features/AI/Model/JSONValue.swift \
                           Smallcast/Features/MCP/Model/*.swift \
                           Smallcast/Features/MCP/Settings/MCPSettingsStore.swift
run -O text-diff-test      Smallcast/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Smallcast/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/AI/Model/AIConnection.swift \
                           Smallcast/Features/AI/Model/AppleIntelligence.swift \
                           Smallcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Smallcast/Features/AI/Model/InstalledAI.swift \
                           Smallcast/Features/QuickActions/Model/*.swift \
                           Smallcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/AI/Model/*.swift \
                           Smallcast/Features/AI/Service/AIProvider.swift \
                           Smallcast/Features/AI/Service/AppleIntelligenceProvider.swift
run slow mcp-stdio-test    Smallcast/Platform/ExecutableLocator.swift \
                           Smallcast/Platform/KeychainSecretStore.swift \
                           Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/AI/Model/AIConnection.swift \
                           Smallcast/Features/AI/Model/AppleIntelligence.swift \
                           Smallcast/Features/AI/Model/AITool.swift \
                           Smallcast/Features/AI/Model/AIStreamDecoder.swift \
                           Smallcast/Features/AI/Model/AIRequest.swift \
                           Smallcast/Features/AI/Model/JSONValue.swift \
                           Smallcast/Features/MCP/Model/*.swift \
                           Smallcast/Features/MCP/Service/*.swift
run slow codex-turn-test   Smallcast/Platform/AppPaths.swift \
                           Smallcast/Features/AI/Model/*.swift \
                           Smallcast/Features/AI/Service/AIProvider.swift \
                           Smallcast/Features/AI/Service/ChatGPTSubscriptionManager.swift \
                           Smallcast/Features/AI/Service/CodexAppServerClient.swift \
                           Smallcast/Features/AI/Service/CodexHomeLocator.swift \
                           Smallcast/Platform/ExecutableLocator.swift \
                           Smallcast/Features/AI/Service/CodexTurnRunner.swift
run installed-ai-test     Smallcast/Features/AI/Model/*.swift \
                          Smallcast/Features/AI/Service/AIProvider.swift \
                          Smallcast/Platform/ExecutableLocator.swift \
                          Smallcast/Features/AI/Service/InstalledCLIProvider.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${SMALLCAST_TEST_JOBS:-$(sysctl -n hw.ncpu)}"
export SMALLCAST_TEST_TIMEOUT="${SMALLCAST_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
