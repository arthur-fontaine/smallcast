#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/smallcast-harness"
mkdir -p "$BIN"

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

# run <name> <source...> — compile the harness and run it, recording either kind of failure.
run() {
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
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
        # Claim only the harness itself. The command still lists every shipped source it compiles, so
        # symbols resolve inside the harness — but claiming those sources here would hand them this
        # 3-file command instead of the app's, and `.compile` is last-wins.
        printf '","files":["%s/Tests/%s.swift"]}' "$PWD" "$name" >> "$DB"
        return 0
    fi

    if ! swiftc -swift-version 6 "$@" "Tests/$name.swift" -o "$BIN/$name" 2>&1; then
        printf '\033[31mFAIL\033[0m  %-22s did not compile\n' "$name"
        failed+=("$name")
        return 0
    fi
    if ! "$BIN/$name"; then
        printf '\033[31mFAIL\033[0m  %-22s assertion failed\n' "$name"
        failed+=("$name")
        return 0
    fi
    printf '\033[32mok\033[0m    %-22s\n' "$name"
}

L=Smallcast/Features/Launcher/Model
run fuzz-test              $L/SearchRelevance.swift
run file-search-test       $L/SearchRelevance.swift \
                           Smallcast/Features/FileSearch/Model/*.swift
run file-search-session-test Smallcast/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Smallcast/Features/FileSearch/Model/*.swift \
                             Smallcast/Features/FileSearch/Service/*.swift
run ranking-test           $L/SearchRelevance.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run launch-history-test    $L/LaunchHistoryStore.swift
run favorites-test         $L/FavoriteSlots.swift
run calc-test              Smallcast/Features/Calculator/Model/*.swift
run clipboard-test         Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift
run emoji-test             Smallcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Smallcast/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Smallcast/Features/Emoji/Model/EmojiData.generated.swift
run palette-selection-test Smallcast/Features/PaletteRowIndex.swift \
                           Smallcast/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/Features/Settings/AppAppearance.swift
run palette-placement-test Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/Palette/PalettePlacement.swift
run scroll-reveal-test     Smallcast/DesignSystem/Scrolling/SelectionReveal.swift
run hover-arming-test      Smallcast/Palette/HoverArming.swift \
                           Smallcast/Palette/PaletteState.swift \
                           Smallcast/Palette/PaletteMode.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift
run hotkey-test            Smallcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Smallcast/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Smallcast/Features/HotKeys/Model/HyperKey.swift \
                           Smallcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Smallcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Smallcast/Features/Launcher/Model/CommandID.swift \
                           Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/SystemActions/Model/SystemAction.swift \
                           Smallcast/Features/WindowManagement/WindowCommand.swift
run callout-test           Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift
run entry-icon-test        Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift
run ext-icon-test          Smallcast/Platform/Appearance.swift \
                           Smallcast/Platform/Images/IconCache.swift \
                           Smallcast/Features/Extensions/Service/ExtensionIconCache.swift
run system-action-test     Smallcast/Features/SystemActions/Model/SystemAction.swift
run volume-test            Smallcast/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Smallcast/Features/WindowManagement/WindowCommand.swift \
                           Smallcast/Features/WindowManagement/WindowLayout.swift \
                           Smallcast/Features/WindowManagement/WindowActionMemory.swift
run space-gesture-test     Smallcast/Features/WindowManagement/WindowCommand.swift \
                           Smallcast/Features/WindowManagement/SpaceGesture.swift
run custom-command-test    Smallcast/Features/CustomCommands/Model/CustomCommand.swift \
                           Smallcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run uninstall-test         Smallcast/Features/Uninstall/Model/UninstallTarget.swift \
                           Smallcast/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Smallcast/Features/Uninstall/Model/UninstallRules.swift \
                           Smallcast/Features/Uninstall/Model/UninstallProtection.swift \
                           Smallcast/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Smallcast/Features/Quicklinks/Model/Quicklink.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Smallcast/Features/Quicklinks/Model/QuicklinkArchive.swift
run snippets-test          Smallcast/Platform/NotificationToken.swift \
                           Smallcast/Platform/HealthTicker.swift \
                           Smallcast/Platform/AccessibilityText.swift \
                           Smallcast/Features/Snippets/Model/*.swift \
                           Smallcast/Features/Snippets/Service/*.swift
run notes-test             Smallcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Smallcast/Features/Notes/Model/*.swift \
                           Smallcast/Features/Notes/Service/*.swift
run notes-editor-test      Smallcast/Platform/Signposts.swift \
                           Smallcast/Platform/Appearance.swift \
                           Smallcast/DesignSystem/Theme.swift \
                           Smallcast/Features/Notes/Model/NoteDocument.swift \
                           Smallcast/Features/Notes/UI/NoteTextView.swift \
                           Smallcast/Features/Notes/UI/NoteEditorView.swift
run raycast-test           Smallcast/Features/Backup/Model/RaycastFormat.swift \
                           Smallcast/Features/Backup/Model/RaycastV1Decoder.swift \
                           Smallcast/Platform/Compression/Zlib.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Smallcast/Features/Clipboard/Model/ClipboardFilter.swift
run settings-backup-test   Smallcast/Features/Settings/AppSettingsKey.swift \
                           Smallcast/Features/Backup/Model/SettingsBackupCoverage.swift
E=Smallcast/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Model/ExtensionManifest.swift
run ext-store-test         $E/Model/ExtensionRegistry.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-test               -parse-as-library \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/RenderNode.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Smallcast/Platform/Compression/Zlib.swift
run settings-history-test  Smallcast/Features/Settings/SettingsTab.swift \
                           Smallcast/Features/Settings/SettingsHistory.swift
run updates-test           Smallcast/Features/Updates/Model/*.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    python3 - .compile "$DB" <<'PY'
import json, sys

compile_path, harness_path = sys.argv[1], sys.argv[2]
existing = json.load(open(compile_path))
harnesses = json.load(open(harness_path))
kept = [e for e in existing if not any("/Tests/" in f for f in e.get("files") or [])]
json.dump(kept + harnesses, open(compile_path, "w"), indent=1)
print(f"{len(harnesses)} harness entries indexed into .compile")
PY
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

if [ ${#failed[@]} -gt 0 ]; then
    printf '\n%d harness(es) failed: %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
echo
if [ -n "$only" ]; then echo "$only passed."; else echo "All $ran harnesses passed."; fi
