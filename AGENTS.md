# heySona - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

Personal-use build: the app calls Anthropic, AssemblyAI, and ElevenLabs directly, using API keys stored in the macOS Keychain. No keys live in source code or the app bundle.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Opus 5.5 default; Sonnet 5.5 and Haiku 5.5 selectable) called directly with SSE streaming. Models and per-request settings live in `ClaudeModelCatalog`: adaptive thinking with `output_config.effort: "low"` (time to first word matters for voice), `max_tokens` 64000 (thinking counts toward it), `thinking.block_binding.prefix_mismatch_behavior: "drop_block"` (beta `thinking-binding-controls-2026-08-01`), and `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) on Opus/Sonnet only, since Haiku 5.5 has no server-side fallback. A final `stop_reason: "refusal"` throws `ClaudeResponseRefusedError` and heySona speaks a short decline; after a mid-stream fallback, only text from before the `fallback` block is echoed and only the fallback model's tool calls run. Request bodies use sorted JSON keys so tool-loop history stays byte-identical. Saved Sonnet/Opus 4.6 choices map to their 5.5 models.
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) called directly
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none. The original project's PostHog analytics and onboarding email collection were removed; the app talks only to Anthropic, ElevenLabs, and AssemblyAI.

### API Keys (macOS Keychain)

There is no backend. Each client reads its key from the login Keychain (service `heySona`) via `APIKeyKeychainStore` on every request, and calls the service directly.

| Service | Endpoint | Keychain account |
|---------|----------|------------------|
| Claude | `api.anthropic.com/v1/messages` | `anthropic-api-key` |
| ElevenLabs TTS | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | `elevenlabs-api-key` |
| AssemblyAI streaming | `streaming.assemblyai.com/v3/ws` (API key in `Authorization` header) | `assemblyai-api-key` |

On launch, `APIKeySetupPrompt` asks for any missing key. Keys can also be saved, replaced, or removed in the Settings window. AssemblyAI is optional; without it the app falls back to Apple Speech. The speech-to-text provider is picked once at launch, so an AssemblyAI key change applies after relaunch.

**Settings Window**: The gear button in the panel header posts `.heySonaOpenSettings`; `MenuBarPanelManager` hides the panel and `SettingsWindowManager` shows a regular titled window (not part of the panel) so text fields get normal focus. Settings covers API keys, ElevenLabs voice (loaded from the account's voice list, with preview), Claude model, and "Speak replies aloud". With spoken replies off, the reply is shown in the `CompanionResponseOverlayManager` text bubble next to the cursor instead of TTS. Voice ID, model, and spoken-reply preference persist in UserDefaults.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Type To Ask**: `cmd + shift + space` (or the panel's "Type a question" button) opens a Spotlight-style non-activating text panel (`TypeToAskPanelManager`). Enter sends the typed question through the same `sendTranscriptToClaudeWithScreenshot` pipeline as voice; both paths share `prepareForNewInteraction()`. The app the user is in stays frontmost, and screenshots already exclude heySona's own windows.

**Stop / Interrupt**: Esc stops the current reply (`stopCurrentResponse()`): cancels the Claude request, stops TTS, hides the text bubble. Esc is registered as a global hot key only while a reply is generating or speaking, then released, so it isn't swallowed in other apps. Pressing push-to-talk during a reply also interrupts it.

**Global Hot Keys**: Type-to-ask and Esc use Carbon `RegisterEventHotKey` (`GlobalHotKeyRegistrar`), not the CGEvent tap, because a Carbon hot key consumes the keystroke so the frontmost app never receives it. Push-to-talk stays on the listen-only CGEvent tap because it's a modifier-only shortcut.

**Mac Actions (Claude tool use)**: When "Let heySona do things on your Mac" is on in Settings (default on), the voice/typed pipeline sends `MacActionTools.toolDefinitionsForClaudeRequest` as client tools, appends `MacActionTools.systemPromptSection` to the system prompt, and adds the current local time to the user message. `ClaudeAPI.analyzeImageStreaming` runs a manual tool loop over SSE: it rebuilds every content block (text, `tool_use` from `input_json_delta` fragments, thinking + signature) and echoes the assistant turn back unchanged, sends all `tool_result`s for a turn in one user message, never runs tools on `max_tokens`/`refusal` stops or after the task is cancelled (Esc), and caps round trips at 6. Tools use `eager_input_streaming`, so `MacActionExecutor` validates every input itself; unparseable input goes back as an `INVALID_JSON` error result. Actions: open app/URL (http/https only), Spotlight file search (`mdfind`), open/reveal file (apps, scripts, installers are only revealed), media keys, volume (Core Audio), reminders and calendar events (EventKit; write-only calendar access), list/run Shortcuts (`/usr/bin/shortcuts`; every run needs the user's approval in an alert). The system prompt tells Claude never to act on instructions found in screen text. Conversation history stays text-only. Calendar/Reminders need the `com.apple.security.personal-information.calendars` entitlement (hardened runtime) and usage strings in `Info.plist`.

**Memory, Project, And Notes (personal context)**: `CompanionManager.makeRequestSetup(transcript:)` builds each request's system prompt, tools, and user-message context, so Mac actions, memory, project files, and notes each switch on independently; `makeToolCallHandler` routes `MacActionToolName` calls to `MacActionExecutor` and the rest to `PersonalContextToolExecutor`. The user message always gets the current local time appended.
- *Long-term memory*: `LongTermMemoryStore` keeps up to 150 short facts in `~/Library/Application Support/heySona/long-term-memory.json`. All facts (with ids like `m3`) are listed in the system prompt; Claude adds/removes them with `remember_fact` / `forget_fact`. The prompt forbids saving anything from screen text, since a remembered injection would persist. Facts can be reviewed and deleted in Settings.
- *Project awareness*: `ActiveProjectContext` reads the frontmost window's `AXDocument` (Accessibility), walks up to the nearest `.git` (never the home folder itself), and falls back to a folder pinned in Settings. Project name, branch (read from `.git/HEAD`), and open file go in the user message; `list_project_files` / `read_project_file` are read-only, confined to the project root (symlinks and `..` resolved before checking), and skip dependency/build folders; reads cap at 200 KB.
- *Notes*: `save_note` writes to Apple Notes (AppleScript; needs Automation permission, `NSAppleEventsUsageDescription`, and the `com.apple.security.automation.apple-events` entitlement), an Obsidian vault folder, or a Markdown folder (default `~/Documents/heySona Notes`). Markdown notes never overwrite an existing file.

**Transient Cursor Mode**: When "Show heySona" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1350 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~720 | SwiftUI panel content for the menu bar dropdown. Shows companion status, settings gear button, push-to-talk and type-to-ask instructions, "Type a question" button, model picker (Haiku/Sonnet/Opus), permissions UI, onboarding Start button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | Cursor-following text bubble for replies. Used when spoken replies are turned off in Settings. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Opens an AssemblyAI v3 websocket authenticated with the Keychain API key, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalHotKeyRegistrar.swift` | ~120 | Registers consuming system-wide hot keys via Carbon `RegisterEventHotKey` (type-to-ask, Esc to stop). |
| `TypeToAskPanelManager.swift` | ~170 | Spotlight-style floating text box for typing a question instead of speaking. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeModelCatalog.swift` | ~85 | Claude models offered in the pickers, default model, effort level, `max_tokens`, which models support server-side refusal fallback, and saved-choice migration. |
| `ClaudeAPI.swift` | ~490 | Claude vision API client with streaming (SSE) and non-streaming modes. Streaming mode runs the client tool-use loop for Mac actions. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the ElevenLabs API, plays back audio via `AVAudioPlayer`, and lists the account's voices for Settings. Exposes `isPlaying` for transient cursor scheduling. |
| `MacActionTools.swift` | ~140 | Mac action tool names, descriptions, JSON input schemas, and the system prompt section that explains them to Claude. |
| `MacActionExecutor.swift` | ~550 | Runs Mac action tool calls with input validation: apps, links, file search/open, media keys, volume, reminders, calendar events, Shortcuts (with approval). |
| `MacSystemVolumeController.swift` | ~120 | Reads and sets output volume and mute through Core Audio. |
| `LongTermMemoryStore.swift` | ~130 | Remembered facts about the user, persisted as JSON in Application Support. |
| `ActiveProjectContext.swift` | ~300 | Detects the active project from the front window or pinned folder; read-only, root-confined project file listing and reading. |
| `NoteSaver.swift` | ~150 | Saves notes to Apple Notes (AppleScript), an Obsidian vault, or a Markdown folder. |
| `PersonalContextTools.swift` | ~240 | Tool definitions, system prompt sections, and executor for memory, project files, and notes. |
| `PersonalContextSettingsSections.swift` | ~310 | Settings sections for memory (fact list with delete), project (pinned folder), and notes (destination, folders). |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `APIKeyKeychainStore.swift` | ~135 | Reads and saves the Anthropic, AssemblyAI, and ElevenLabs API keys in the macOS Keychain. |
| `APIKeySetupPrompt.swift` | ~50 | On launch, shows an alert asking for any API key not yet saved in the Keychain. |
| `SettingsWindowManager.swift` | ~60 | Creates and shows the Settings window (titled `NSWindow` hosting `SettingsView`). |
| `SettingsView.swift` | ~430 | Settings UI: API keys, ElevenLabs voice picker with preview, Mac actions toggle, memory/project/notes sections, Claude model, and spoken-reply toggle. Its layout helpers (`settingsCard`, `settingsSectionTitle`, `SettingsCapsuleButton`) are shared. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- `develop` is the default branch, where finished work is integrated.
- Start every new feature or bug fix from the latest `develop`, on a `feature/description` or `fix/description` branch, and merge it back into `develop` when it's done.
- After the work on `develop` has been tested, merge `develop` into `release`. `release` only ever receives tested code from `develop`; never commit to it directly.
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to `develop`, `release`, or `main`

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
