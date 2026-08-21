# AI

Ask a question from the launcher and read the answer in the palette. The provider is the user's own —
any endpoint that speaks the OpenAI chat API, a local LM Studio, or a local Ollama — and the credential
never leaves the Keychain. Off by default.

## Invariants

- **Everything under `Model/` stays Foundation-only and pure.** `ai-test` compiles the shipped request
  builder, the stream decoder, the archive and the chord table, so a decision cannot leak into the
  effect layer.
- **`AIStreamDecoder` buffers bytes, not text.** A chunk boundary can land inside a multi-byte scalar,
  and decoding each half on its own loses the character. `ai-test` pins that case by cutting a line
  through `é`.
- **The credential lives in the Keychain and nowhere else.** No `AppSettings` key holds it, so no
  settings backup can carry it to another Mac. `Platform/Keychain.swift` is the one accessor, scoped to
  the running bundle so `Smallcast Dev` never reads the installed app's secret.
- **`aiEnabled` doubles as consent to send typed text off the machine**, so it defaults off and is
  excluded from a settings backup — the same call as `snippetsEnabled` and `extensionsEnabled`.
- **The request goes out on a private `.ephemeral`, `urlCache = nil` session**, never
  `URLSession.shared`, so no prompt or answer is written to a cache Smallcast shares. `AIClient` is the
  only network path the feature has.
- **Reasoning text is never the answer.** A reasoning model streams `reasoning_content` long before its
  first word — measured at 594 chunks for one question against a local 0.8B model. Those become
  `.reasoning` / `.thinking`, which drive a "Thinking…" label and nothing else. Private thinking never
  enters the transcript, is never persisted, and is never sent back as context.
- **Test Connection returns on the first event of any kind.** Waiting for a whole answer reported a
  working server as broken, because a reasoning model can think past the request timeout. A thinking
  chunk *is* the server answering.
- **A failed turn renders inline, never as a dialog.** The question is still on screen, so the answer's
  own row is where the reason belongs. `AIMessage.failure` carries it, and a failed turn is excluded
  from the context the next request sends.
- **AI owns its own markdown renderer.** `ExtensionMarkdownView` is the extension host's and must stay
  free to change without this following it; duplicating the block layout is the correct trade, the same
  one [extensions.md](extensions.md) already makes.
- **The chord fires from root search only, and never consults the rows.** A query that matched nothing
  is exactly when it is most wanted.

## The chord

`AppSettings.aiChord` is a `PaletteAIChord` — ⌥↵ (default), ⌃↵ or ⇥ — deliberately a picker rather
than a `ShortcutRecorder`. The recorder records a *global* Carbon chord and registers it with
`HotKeyCenter`; this is an in-palette key, which is a different mechanism.

`PaletteAIChord` names its modifier in its own terms (`.option`, `.control`) rather than SwiftUI's
`EventModifiers`, which is what keeps the file Foundation-only. `RootPaletteView.holds(_:in:)` is the
one place that mapping lives.

The handler sits ahead of every other modified-↵ rule in `RootPaletteView`, because *which* modified ↵
this is, is the setting's to say. Elsewhere ⌥↵ keeps its usual meaning: on the clipboard and emoji
screens it is still `pasteKeepingWindowOpen`, which the launcher screen never answered.

⇥ still cycles launcher ↔ clipboard whenever the chord doesn't fire, which is any empty query.

## Screens

| Mode | Screen | What it is |
| --- | --- | --- |
| `.aiChat` | `AIChatScreen` | the live conversation; the search field is the **composer**, so ↵ sends |
| `.aiChats` | `AIChatListScreen` | saved conversations under the shared `DateBucket` headers |

`.aiChat` is the second mode after `.quicklinkArguments` where the search field is not a filter, and
`RootPaletteView` names both in the `showActionGroup` condition so the ↵ pill shows on a chat with no
rows yet.

⌘K carries Stop (while streaming), Copy Answer, Regenerate (⌘R), New Chat (⌘N) and Search AI Chats.
⌘R and ⌘N arrive through `AIChatShortcutKeys` rather than an inline handler: `RootPaletteView.body` is
long enough that one more `onKeyPress` in the chain stops type-checking.

Leaving `.aiChat` cancels the stream, beside the existing File Search and extension cleanup in
`onChange(of: vm.mode)`. `AIChatSession.cancel` also drops a half-streamed answer with nothing in it,
so the transcript is never left holding a blank turn.

## Providers

Every provider takes the **same request body** — `model`, `stream: true`, `messages` — so
`AIRequestBuilder` has one shape. They differ in three things only:

| | OpenAI-compatible | LM Studio | Ollama |
| --- | --- | --- | --- |
| Path | `chat/completions` | `chat/completions` | `api/chat` |
| Credential | `Authorization: Bearer …` | none | none |
| Framing | SSE, ended by `[DONE]` | SSE, ended by `[DONE]` | one JSON object per line, ended by `"done": true` |

LM Studio is a separate case rather than "use OpenAI-compatible with a different address" because its
defaults are its own: `http://localhost:1234/v1`, no credential, and **no default model at all**. It
names a model by whatever was downloaded (`qwen3.5-0.8b`, `google/gemma-4-e2b`), so guessing one would
only ever be wrong. Its port is configurable there and often is not 1234.

### The model menu

`AIModelList` decodes what a server reports — `data[].id` for the OpenAI shape, `models[].name` for
Ollama — and the Settings pane fills a menu from it. The **field stays free text**: a listing endpoint
that doesn't answer costs nothing, and a pasted id still works.

Embedding models are dropped by name. No listing endpoint says what a model is *for*, and LM Studio
lists its five embedding models beside the seven that can hold a conversation.

LM Studio ignores an unknown model name and answers with whatever is loaded, so a wrong model is not an
error it reports. Nothing here tries to make it one.

`AIProviderConfig.endpoint` checks the scheme against `http`/`https` rather than merely being present:
`localhost:11434` parses as a URL whose *scheme* is `localhost`, which would otherwise read as valid.

A non-200 answer is read as a whole body and mined for its message
(`AIStreamDecoder.message(in:)`), so a wrong key reports "bad key" rather than "HTTP 401".

## History

`AIConversationStore` keeps chats in `ai-conversations.json` under Application Support, rewritten whole
after every turn: a transcript is small and the list is capped at
`AIConversationArchive.conversationLimit`, so nothing an append-only format would buy applies. Newest
first, and a chat with no messages is never written — an abandoned New Chat is not history.

A conversation has no stored title. `AIConversation.title` is the first question asked, trimmed to one
line, so a title cannot drift from what the chat is about.

## Commands

`CommandID.askAI` and `.searchAIChats` publish through `AppIndex.setCommandsVisible`, driven by
`AICoordinator.applyEnabled()` — the Notes precedent. Both are bindable to a global shortcut
(`HotKeyAction.askAI`, `.searchAIChats`); `hotkey-test` pins the mapping.

Turning the feature off removes both commands, cancels any stream, and pops the palette back to the
launcher if it was on either AI screen.
