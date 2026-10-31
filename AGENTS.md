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
- **Speech-to-Text**: chosen in Settings > Speech to text (`SpeechToTextChoice`, saved in UserDefaults, switchable without relaunch via `BuddyDictationManager.reloadTranscriptionProvider()`): AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, or WhisperKit (Swift package `argmaxinc/argmax-oss-swift` 1.1.x, product `WhisperKit`, MIT) on-device. With no saved choice, `VoiceTranscriptionProvider` in Info.plist decides; OpenAI and Apple Speech remain fallbacks.
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) called directly, or the free built-in Mac voice (Settings > Voice). `ElevenLabsTTSClient` routes every request: with the Mac voice chosen, no ElevenLabs key, or after an ElevenLabs failure (out of credits, bad key, offline; ElevenLabs is then skipped for 10 minutes and Settings shows why), `MacSystemVoiceAudioRenderer` renders speech with `AVSpeechSynthesizer.write` into CAF audio data, so it plays through the same `AVAudioPlayer` path and streaming speech, step guidance (timing estimated, no timestamps), and explainer narration work unchanged.
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

On launch, `APIKeySetupPrompt` asks for any missing key. Keys can also be saved, replaced, or removed in the Settings window. AssemblyAI and ElevenLabs are optional; without them the app falls back to Apple Speech and the Mac voice (the launch prompt skips the ElevenLabs key when the Mac voice is chosen). The speech-to-text provider is picked once at launch, so an AssemblyAI key change applies after relaunch.

**Settings Window**: The gear button in the panel header posts `.heySonaOpenSettings`; `MenuBarPanelManager` hides the panel and `SettingsWindowManager` shows a regular titled window (not part of the panel) so text fields get normal focus. Settings covers API keys, ElevenLabs voice (loaded from the account's voice list, with preview), Claude model, and "Speak replies aloud". With spoken replies off, the reply is shown in the `CompanionResponseOverlayManager` text bubble next to the cursor instead of TTS. Voice ID, model, and spoken-reply preference persist in UserDefaults.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` and a custom borderless, non-activating `NSPanel`. Its quiet view is 360 x 380 points; typing or viewing a reply expands it to 440 x 560 (height capped to the available screen). `DS.CompanionPanel` supplies adaptive light/dark surfaces, native text colors, a blue accent, and consistent corners; the window server draws its shadow. `MenuBarPanelManager` observes expansion and setup readiness, animates resizing unless Reduce Motion is on, and clamps the frame to the status item's screen. Outside clicks dismiss it. Settings and quit/onboarding actions remain available in the header; Library, Last reply, and model controls sit in the footer.

**Panel Conversation**: `CompanionPanelConversation` owns the latest exchange in memory, independently of the saved archive. The main pipeline streams readable text into it for both spoken and text-only replies, strips complete and partial visual/control tags, preserves interrupted text, and ignores stale callbacks using exchange ids. The expanded panel supports selection, copy, inline follow-ups, stop, collapse, and reopening the last reply. Submitting from the panel restores the previous app and waits 0.15 s before the shared typed-question pipeline captures the screen and builds request context; only then does `.heySonaShowConversationPanel` reopen it without taking keyboard focus. Background voice and Spotlight questions never auto-open this panel. Clear History also clears the visible exchange.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**On-Device Speech (WhisperKit)**: `WhisperKitTranscriptionProvider` buffers push-to-talk audio (16 kHz PCM16 via `BuddyPCM16AudioConverter`) and transcribes it on key release through `WhisperKitSpeechModelManager.shared`, which downloads the chosen model once from Hugging Face (`argmaxinc/whisperkit-coreml`) into `~/Library/Application Support/heySona/speech-models` (tokenizer too, so it works offline), loads it at launch or when picked, and unloads it when switching to AssemblyAI. Models: Fast `base.en` (147 MB, about 0.2 s per 11 s question on an M4) and Most accurate `large-v3-v20240930_626MB` (627 MB, about 1.2 s; its first-ever load takes 1-2 minutes while macOS optimizes it). Key terms are passed as Whisper prompt tokens, which fixes spellings like "Dijkstra" and "A*". Clips under a third of a second return empty text; if the model isn't ready within 25 s of key release, the session reports an error.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Type To Ask**: double-tapping `control` (or the panel's "Type a question" button) opens a Spotlight-style non-activating text panel (`TypeToAskPanelManager`). Enter sends the typed question through the same `sendTranscriptToClaudeWithScreenshot` pipeline as voice; both paths share `prepareForNewInteraction()`. Opening makes heySona the front app so typing lands in the box without a click (through Accessibility's `kAXFrontmostAttribute`, because macOS declines activation requests from an app the user didn't interact with, and the event-tap double-tap doesn't count); Enter or Esc gives focus back to the previous app, and Enter waits 0.15 s so the screenshot and "app in front" describe that app.

**Stop / Interrupt**: Esc stops the current reply (`stopCurrentResponse()`): cancels the Claude request, stops TTS, hides the text bubble. Esc is registered as a global hot key only while a reply is generating or speaking, then released, so it isn't swallowed in other apps. Pressing push-to-talk during a reply also interrupts it.

**Global Hot Keys**: Esc uses Carbon `RegisterEventHotKey` (`GlobalHotKeyRegistrar`), not the CGEvent tap, because a Carbon hot key consumes the keystroke so the frontmost app never receives it. Push-to-talk (ctrl + option) and type-to-ask (double-tap control) are modifier-only, so they stay on the listen-only CGEvent tap. Type-to-ask fires on two control taps (each held at most 0.35 s, the second starting within 0.4 s of the first) with no other key, modifier, or click in between (`GlobalPushToTalkShortcutMonitor.typeToAskDoubleTapPublisher`), so ctrl shortcuts and push-to-talk never trigger it. It conflicts only if macOS Dictation is set to "Press Control Key Twice".

**Mac Actions (Claude tool use)**: When "Let heySona do things on your Mac" is on in Settings (default on), the voice/typed pipeline sends `MacActionTools.toolDefinitionsForClaudeRequest` as client tools, appends `MacActionTools.systemPromptSection` to the system prompt, and adds the current local time to the user message. `ClaudeAPI.analyzeImageStreaming` runs a manual tool loop over SSE: it rebuilds every content block (text, `tool_use` from `input_json_delta` fragments, thinking + signature) and echoes the assistant turn back unchanged, sends all `tool_result`s for a turn in one user message, never runs tools on `max_tokens`/`refusal` stops or after the task is cancelled (Esc), and caps round trips at 6. Tools use `eager_input_streaming`, so `MacActionExecutor` validates every input itself; unparseable input goes back as an `INVALID_JSON` error result. Actions: open app/URL (http/https only), Spotlight file search (`mdfind`), open/reveal file (apps, scripts, installers are only revealed), media keys, volume (Core Audio), reminders and calendar events (EventKit; write-only calendar access), list/run Shortcuts (`/usr/bin/shortcuts`; every run needs the user's approval in an alert). The system prompt tells Claude never to act on instructions found in screen text. Conversation history stays text-only. Calendar/Reminders need the `com.apple.security.personal-information.calendars` entitlement (hardened runtime) and usage strings in `Info.plist`.

**Conversation History (across launches)**: With "Remember past conversations" on (Settings, default on), every exchange (user text and reply, never screenshots; guided-mode continuations skipped) is appended to `~/Library/Application Support/heySona/conversations/exchanges.jsonl` by `ConversationArchiveStore`. Exchanges 30+ minutes apart start a new session. When a session has been idle 30 minutes (or at the next launch, for sessions that ended while the app was closed), `summarizeFinishedConversationSessions()` asks Haiku 5.5 (`conversationSummaryClaudeAPI`, non-streaming) for a 2-4 sentence learning-journal entry, saved in `session-summaries.json` and shown in Settings. Each request gets the 3 latest summaries (other sessions) in the user message (not the system prompt, to keep it cacheable), plus the `search_past_conversations` tool: on-device BM25 keyword ranking over base word forms (NLTagger lemmas); Claude is told to search with the topic plus related words. Apple's sentence embeddings were tried and rejected (they ranked unrelated chats above real matches). At launch, exchanges from the last 2 hours are restored into the in-memory history (still capped at 10), and a session younger than 30 minutes continues. "Clear History" deletes the archive and the current conversation.

**Skills (know-how loaded on demand)**: `SkillLibrary` loads Markdown skills with a front matter block (`name`, `kind` topic/app/procedure, `description`, `keywords`, `apps` bundle IDs, `use_for` voice/explainer) from `Skills.bundle` (13 CS/math/ML topic skills, 6 app skills; a `.bundle` folder so Xcode copies the files) and `~/Library/Application Support/heySona/skills/` (user files replace bundled ones with the same name; procedures in `procedures/`). Each voice request gets app skills for the front app's bundle ID, at most one matching saved procedure for that app, and the 2 best keyword-matched topic skills (`SearchTextNormalizer` word forms; multi-word keywords as phrases), appended to the user message; the skill catalog (names and descriptions) is in the system prompt, which stays cacheable, and `load_skill` fetches any other skill. Visual explanations get the 2 best topic skills in the scene request ("topic recipes"); `sceneAuthoringSystemPrompt` keeps only general drawing rules. Settings > Skills toggles skills, opens the folder, reloads, and shows the last reply's skills. Bodies are capped at 12,000 characters.

**Saved Procedures**: after guiding a multi-step task, Claude asks whether to save the steps; on yes it calls `save_procedure` (title, app bundle ID from the "app in front" line, keywords, numbered steps). `SkillLibrary.saveProcedure` keeps only numbered step lines (so injected text can't persist), requires 2-20 steps, at most 6,000 characters, a valid bundle ID, and a new title, and writes `procedures/<slug>.md`. A matching procedure is added to later requests for that app; Claude follows it against the screenshot and calls `update_procedure` when the app changed. Procedures can be shown or deleted in Settings.

**Visual Self-Check**: (A) always on: about 1.4 s after each explainer step settles (after delayed actions), `checkAndFixCurrentStepLayout()` in `visual-explainer.js` reports unknown ids, nothing visible, objects more than 30% off-stage (fixed by a camera fit unless the user moved the camera in the last 4 s), and overlapping label pills or cards (labels nudged up, or down when there's no room, after clamping), posting `stepIssues` to Swift. (B) optional, Settings > Visuals > "Double-check visuals" (off by default): after a new scene completes, `VisualExplanationReviewer` renders up to 8 steps in a hidden off-screen `WKWebView`, snapshots them (768 px JPEG), and sends them with the scene and the layout issues to Claude (`sceneAuthoringSystemPrompt` plus a review section); corrected steps (JSON Lines with `index`) replace steps the narration hasn't reached (`applyReviewedStepFix`, `heySonaExplainer.replaceStep`) and are saved to the library entry.

**Memory, Project, And Notes (personal context)**: `CompanionManager.makeRequestSetup(transcript:)` builds each request's system prompt, tools, and user-message context, so Mac actions, memory, project files, and notes each switch on independently; `makeToolCallHandler` routes `MacActionToolName` calls to `MacActionExecutor` and the rest to `PersonalContextToolExecutor`. The user message always gets the current local time appended.
- *Long-term memory*: `LongTermMemoryStore` keeps up to 150 short facts in `~/Library/Application Support/heySona/long-term-memory.json`. All facts (with ids like `m3`) are listed in the system prompt; Claude adds/removes them with `remember_fact` / `forget_fact`. The prompt forbids saving anything from screen text, since a remembered injection would persist. Facts can be reviewed and deleted in Settings.
- *Project awareness*: `ActiveProjectContext` reads the frontmost window's `AXDocument` (Accessibility), walks up to the nearest `.git` (never the home folder itself), and falls back to a folder pinned in Settings. Project name, branch (read from `.git/HEAD`), and open file go in the user message; `list_project_files` / `read_project_file` are read-only, confined to the project root (symlinks and `..` resolved before checking), and skip dependency/build folders; reads cap at 200 KB.
- *Notes*: `save_note` writes to Apple Notes (AppleScript; needs Automation permission, `NSAppleEventsUsageDescription`, and the `com.apple.security.automation.apple-events` entitlement), an Obsidian vault folder, or a Markdown folder (default `~/Documents/heySona Notes`). Markdown notes never overwrite an existing file.

**On-Screen Drawing, Captions, And Visual Answers**: With "Draw on screen" on (Settings > Visuals, default on), `ScreenDrawingTagParser.systemPromptSection` asks Claude to point and draw whenever the question is about something visible. Claude appends `[CIRCLE:x,y,r:label:screenN]`, `[BOX:x,y,w,h:...]`, `[ARROW:x1,y1,x2,y2:...]`, `[UNDERLINE:...]` tags before the final `[POINT:...]` tag (no extra round trip, unlike a tool). `ScreenDrawingTagParser.extractDrawings` removes every drawing tag from the reply (always, so tags are never spoken), converts screenshot pixels to display points with the same scaling as pointing, caps at 6 drawings, and falls back to the cursor's screen for unknown screen numbers. `CompanionManager.screenDrawings` is rendered by `ScreenDrawingLayerView` inside each screen's `BlueCursorView`, sketched in one after another with `.trim` animations; labels are kept on screen. Drawings fade 4 s after speech ends (8 s for text-only replies) and are cleared on a new question or Esc; transient cursor mode waits for them. "Show captions" (default on) shows the spoken reply in the `CompanionResponseOverlayManager` bubble until 1.5 s after audio ends.

**Step-By-Step Guidance**: With "Step-by-step guidance" on (Settings > Visuals, default on), `StepGuidanceParser.systemPromptSection` asks Claude to put a `[STEP:x,y:label:screenN]` tag after each step's sentence (one step per sentence, visible targets only, then `[POINT:none]`). Step tags are extracted *after* the POINT tag, so each step's `spokenTextStartCharacterOffset` indexes the exact spoken text; a step starts at its own sentence, not at untagged sentences before it. `CompanionManager.presentReplyWithStepGuidance` speaks through ElevenLabs' `/with-timestamps` endpoint (`speakTextWithCharacterTimestamps`) and shows each step (numbered circle drawing + cursor flight with a "1 · label" bubble) when the voice reaches it; if timestamps are missing or misaligned it estimates from text position, and if that endpoint fails it falls back to plain `speakText`. With spoken replies off, steps advance every 3 s. While `isGuidingThroughSteps` is true the overlay keeps the cursor on the current step instead of flying back. `BlueCursorView.navigationFlightNumber` makes delayed callbacks from an earlier flight no-ops, so consecutive step flights don't cut each other short. When steps are present, any `[POINT]` coordinate is ignored.

**Visual Explainer**: Ask "explain how X works" / "show me…" and heySona opens an animated, narrated 3D model or 2D diagram in its own window.
- *Trigger*: with "Visual explanations" on (Settings > Visuals, default on), `VisualExplanationSession.mainReplySystemPromptSection` tells Claude to answer such questions with a one-sentence spoken lead-in plus a `[VISUAL:brief]` tag. `extractVisualExplanationBrief` strips it before drawing/POINT/STEP parsing. The session starts after the lead-in begins playing so voices never overlap; the brief is noted in conversation history for follow-ups.
- *Generation*: `VisualExplanationSession` makes a second, tool-free streaming Claude request with `sceneAuthoringSystemPrompt` (the scene format plus authoring guidance). Claude writes JSON Lines: line 1 = scene setup, each later line = one step. `JSONLineReader` hands complete lines over as they stream (including the final line without a newline); non-JSON lines are skipped; steps placed inside the setup are split out. If no setup line arrives, the window closes and heySona apologizes.
- *Narration*: with spoken replies on, the session drives the window (`autoAdvance: false`): for each step it calls `goToStep`, plays the step's narration (prepared one step ahead with `synthesizeSpeechAudio`), waits for it to finish, and continues; it waits for steps that are still streaming. Window controls feed back via `stepStarted` (a step the session didn't request means the user navigated, so narration jumps there, or restarts after finishing) and `playPauseRequested` (pauses/resumes the audio). With spoken replies off, the window auto-advances on reading time. A new question or Esc stops generation and narration; closing the window does too.
- *Renderer*: `VisualExplainerPanelManager` hosts a `WKWebView` loading `VisualExplainer.bundle/visual-explainer.html` and queues commands until the page posts `ready`. The page renders the scene description (data, never code) with bundled three.js r160 (MIT; verified against npm's sha512). Shapes: box, sphere, cylinder, cone, torus, lathe, tube, line (graphs/axes/timelines; `"drawn": false` + `draw` traces it), rect, circle, ring, card (HTML text box). Actions: show/hide, focus/unfocus, highlight, cutaway, color, label/unlabel, arrow, flow (drawn on top so it glows through pipes), plume, spin, revolve, move, draw, add (objects mid-explanation), camera (`"fit": [ids]` auto-framing with a minimum close-up distance), orbit, clearEffects. Labels stay inside the stage. The full format and JS API are documented at the top of `visual-explainer.js`; keep `sceneAuthoringSystemPrompt` in sync with it. Files live in a `.bundle` folder because Xcode treats loose `.js` files as sources and wouldn't copy them. Settings > Visuals > "Show rocket demo" plays `visual-explainer-demo-rocket.json`.

**Streaming Speech And Prompt Caching**: With spoken replies on, `StreamingReplySpeaker` (in `StreamingSpeech.swift`) voices the reply while it streams: `SpokenTextStreamSegmenter` cuts the growing text into sentences (merging short ones after the first; a sentence followed by a tag is always its own segment) and pulls out complete `[TAG:...]`s; `StreamingSpeechPlayer` synthesizes segments with ElevenLabs (at most two ahead) and plays them back to back. `[STEP]` tags are attached to the sentence before them and fire when it starts playing, so streamed step-by-step guidance needs no timestamps (the timestamp path in `presentReplyWithStepGuidance` is now only used for text-only replies). `[POINT]`, drawings, and `[VISUAL]` are still processed once the reply ends, so pointing may start mid-speech. A visual explanation's narration waits for the streamed lead-in via `waitForLeadInToFinish`. Captions show the current sentence. With spoken replies off, the old wait-for-the-whole-reply path is unchanged. `ClaudeAPI` sends the system prompt as a block with `cache_control: ephemeral`, caching tools + system across requests; `message_start` usage is logged as "🌐 Claude prompt cache: N read, N written".

**Pro-App Guidance**: (1) *App awareness*: `frontmostApplicationDescription()` adds "app in front: <name> <version>" to every user message so menus and shortcuts match the user's version. (2) *Sharper screenshots*: the cursor's screen is captured at `ClaudeModelCatalog.screenshotMaximumLongEdgeInPixels` (1920 for Opus/Sonnet 5.5, which read up to 2576 px with 1:1 coordinates; 1568 for Haiku 5.5, whose limit isn't documented, because a larger image would be downscaled by the API and break pointing); other screens use 1024; nothing is upscaled past native resolution. (3) *Guided mode* (`CompanionManager+GuidedMode.swift`, Settings > Visuals, on by default, needs step-by-step guidance): Claude guides the steps it can see and ends with `[WAIT_FOR_CLICK]` when the task continues past the current screen. After the reply, heySona keeps the step circles up, shows a waiting hint, watches for the next left click in another app (global monitor), waits 1.2 s for the app to react, then sends a continuation message with a fresh screenshot repeating the original request. It ends when a reply has no tag, after 10 rounds, after 3 minutes without a click, on Esc (the reply's Esc stays armed while waiting), or on a new question (`isContinuingGuidedTask` keeps a guided round from ending itself).

**Explainer Library, Follow-Ups, Quiz, And Parts**: `VisualExplanationSession` has three sources (`VisualExplanationSource`): `.newTopic` (Claude writes a scene), `.followUp(existingSceneLines:)` (Claude writes only new steps for the open scene, using `followUpAuthoringPromptSection`; new step indexes continue after the existing ones and the window is reopened with `continueScene()`), and `.saved(sceneLines:)` (replay from disk, no Claude call). Every played line is recorded (setup normalized, steps, quiz) and `onSceneCompleted` saves it via `ExplanationLibraryStore` (`~/Library/Application Support/heySona/explanations/<uuid>.json`; a follow-up updates the same entry) and sets `CompanionManager.openVisualExplanation`. While the window shows an explanation, the main prompt adds `followUpMainReplySystemPromptSection`, and Claude answers related questions with `[VISUAL_FOLLOWUP:brief]` (parsed before `[VISUAL]`). The window's Library button lists saved explanations (Play/Delete), also reachable from Settings > Visuals > Open library; closing the window clears `openVisualExplanation`. Scenes end with a `{"quiz": [...]}` line (2-3 multiple-choice questions) shown after the last step (with a spoken invitation) or via the Quiz button. Pre-built shapes: `gear` (toothed, extruded), `capsule`, `spring` (helix). `configureVisualExplainerWindowCallbacks()` (idempotent) wires the window's library, concept map, and close callbacks.

**Simple English, Analogies, And Connected Ideas (learning)**: heySona is mainly used to learn computer science, math, data structures and algorithms, machine learning, deep learning, and AI agents. The voice prompt (`companionVoiceResponseSystemPrompt`) and `sceneAuthoringSystemPrompt` ask for simple English (everyday words, jargon defined on first use, intuition before formulas, small concrete numbers), one real-world analogy per explanation (with where it breaks down), and links to related ideas; the authoring prompt has a playbook for drawing arrays, trees/graphs, algorithms, Big O, recursion, math graphs, neural networks, gradient descent, attention, agent loops, and code (`card` with `"code": true`). "Simpler, please" goes through the follow-up path and re-explains with a different analogy. Scenes end with a `{"concepts": {"main", "related", "prerequisites"}}` line, parsed by `VisualExplanationSession` (never shown or replayed) and saved as `SavedExplanation.concepts` (optional, so older files still load; a follow-up keeps the main concept and merges related ideas). `ExplanationLibraryStore.learnedTopicsDescription()` lists learned topics; it goes into the scene request and the main reply's user-message context (not the system prompt, which stays cacheable) so new answers build on old ones. `conceptGraphJSON()` builds the concept map (topics plus related ideas, matched by `normalizedConceptName`; a related idea that is itself a learned topic links the two topics). The window's Map button and Settings > Visuals > Concept map open it (`showConceptMap`); the page lays it out with a small force simulation and clicking a topic replays it. Active recall and spaced review are intentionally not built (the user reviews manually).

**Equations, Timing, And Live Sliders (explainer)**: (1) *Equations*: cards take `"math"` (LaTeX) and labels take `"math"`, typeset by bundled KaTeX 0.18.11 (MIT, `VisualExplainer.bundle/katex/`, verified against npm's sha512; `trust` stays off). `{"do":"update"}` changes a card's title/text/math with a soft transition (equation transforms). (2) *Timing*: any action can have `"delay"`; delayed actions wait in `pendingDelayedActions` (scene time, frozen while paused) and are applied instantly when the step changes or playback finishes. (3) *Live sliders*: `{"do":"slider", "id", "label", "min", "max", "step", "value"}` shows a slider (top-left panel) whose id is a variable; setup `"variables"` gives starting values. Objects react through a small hand-written expression parser (numbers, variables, + - * / ^ %, implicit multiplication, pi, e, a fixed list of math functions; never `eval`): `"bind"` (position/scale/opacity), line `"plot"` (`y` over a range, or `iterate` for repeated updates like gradient descent, with optional `markers`), and `[[expression]]` live values in card and label text. `applyVariableBindings()` re-applies everything after a slider moves and after resets. When sliders are out at the end, the quiz isn't opened automatically (the Quiz button glows instead). Cards are kept inside the stage.

**Transient Cursor Mode**: When "Show heySona" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1030 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. Feature methods live in `CompanionManager+*.swift` extensions; stored state stays here. |
| `CompanionManager+RequestSetup.swift` | ~120 | Builds each Claude request: tools, system prompt sections for enabled features, user-message context, and the tool-call router. |
| `CompanionManager+Visuals.swift` | ~330 | Screen drawings, captions, step-by-step guidance playback, starting/stopping visual explanations (new, follow-up, replay), and the explainer window's library callbacks. |
| `CompanionManager+GuidedMode.swift` | ~150 | Guided mode: `[WAIT_FOR_CLICK]` handling, waiting for the user's click, continuation rounds, limits, and stopping. |
| `CompanionManager+Shortcuts.swift` | ~125 | Type-to-ask (double-tap control) and Esc-to-stop hot key. |
| `CompanionManager+Permissions.swift` | ~115 | Permission checks, screen content request, permission polling. |
| `CompanionManager+Onboarding.swift` | ~300 | Onboarding video, music, prompt stream, and the pointing demo. |
| `CompanionManager+PointTags.swift` | ~70 | `[POINT:...]` tag parsing. |
| `MenuBarPanelManager.swift` | ~355 | NSStatusItem + adaptive NSPanel lifecycle, anchored quiet/conversation resizing, focus handoff for inline questions, passive reply presentation, and outside-click dismissal. |
| `CompanionPanelView.swift` | ~500 | Adaptive SwiftUI quiet panel, expanded streaming reply with copy and inline follow-ups, setup permissions, header actions, and Library/Last reply/model footer. |
| `CompanionPanelConversation.swift` | ~110 | Latest exchange presentation state, reply cleanup for streamed control tags, interruption/errors, and exchange-id guards against stale callbacks. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | Cursor-following text bubble for replies. Used when spoken replies are turned off in Settings. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~140 | Protocol surface, `SpeechToTextChoice`, and the provider factory: the Settings choice (AssemblyAI or WhisperKit) first, then `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `WhisperKitTranscriptionProvider.swift` | ~340 | On-device speech-to-text: Whisper model choice, download/load state for Settings, key-term prompting, and the push-to-talk session that transcribes on release. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Opens an AssemblyAI v3 websocket authenticated with the Keychain API key, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalHotKeyRegistrar.swift` | ~120 | Registers consuming system-wide hot keys via Carbon `RegisterEventHotKey` (type-to-ask, Esc to stop). |
| `TypeToAskPanelManager.swift` | ~170 | Spotlight-style floating text box for typing a question instead of speaking. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeModelCatalog.swift` | ~85 | Claude models offered in the pickers, default model, effort level, `max_tokens`, which models support server-side refusal fallback, and saved-choice migration. |
| `StreamingSpeech.swift` | ~350 | Speaks replies while they stream: sentence segmenter, ordered ElevenLabs playback queue with look-ahead synthesis, and the reply speaker that ties in step guidance and captions. |
| `ClaudeAPI.swift` | ~490 | Claude vision API client with streaming (SSE) and non-streaming modes. Streaming mode runs the client tool-use loop for Mac actions. TLS warmup optimization, image MIME detection, conversation history support. |
| `MacSystemVoice.swift` | ~230 | Free offline voice: installed macOS voices for the Settings picker (user's language and best quality first, no novelty voices) and rendering speech to audio data off the main actor. |
| `ElevenLabsTTSClient.swift` | ~310 | Speech client: `SpeechVoiceProvider` choice and automatic fallback to the Mac voice. Sends text to the ElevenLabs API, plays back audio via `AVAudioPlayer`, and lists the account's voices for Settings. Exposes `isPlaying` for transient cursor scheduling, and a `/with-timestamps` variant that returns per-character start times for step-by-step guidance. |
| `MacActionTools.swift` | ~140 | Mac action tool names, descriptions, JSON input schemas, and the system prompt section that explains them to Claude. |
| `MacActionExecutor.swift` | ~550 | Runs Mac action tool calls with input validation: apps, links, file search/open, media keys, volume, reminders, calendar events, Shortcuts (with approval). |
| `MacSystemVolumeController.swift` | ~120 | Reads and sets output volume and mute through Core Audio. |
| `ConversationArchive.swift` | ~350 | Conversation archive: saved exchanges and session summaries (JSON Lines/JSON in Application Support), BM25 search, the `search_past_conversations` tool, and the prompts for it and for session summaries. |
| `CompanionManager+ConversationMemory.swift` | ~150 | Sessions (30-minute gap), saving each exchange, Haiku journal summaries of finished sessions, restoring recent context at launch, clearing history. |
| `SkillLibrary.swift` | ~400 | Skill files: loading (bundled and user folders), front matter parsing, enabling, choosing skills for a request or explanation, and saving/updating/deleting procedures. |
| `SkillTools.swift` | ~190 | `load_skill`, `save_procedure`, `update_procedure` tools, the skill catalog prompt section, and matched skills for the user message. |
| `SkillsSettingsSection.swift` | ~150 | Settings section for skills and saved procedures. |
| `Skills.bundle/` | — | Bundled skill Markdown files (13 topic, 6 app). |
| `VisualExplanationReviewer.swift` | ~200 | Optional visual self-check: hidden-webview step snapshots and the Claude review that returns corrected steps. |
| `LongTermMemoryStore.swift` | ~130 | Remembered facts about the user, persisted as JSON in Application Support. |
| `ActiveProjectContext.swift` | ~300 | Detects the active project from the front window or pinned folder; read-only, root-confined project file listing and reading. |
| `NoteSaver.swift` | ~150 | Saves notes to Apple Notes (AppleScript), an Obsidian vault, or a Markdown folder. |
| `PersonalContextTools.swift` | ~240 | Tool definitions, system prompt sections, and executor for memory, project files, and notes. |
| `PersonalContextSettingsSections.swift` | ~400 | Settings sections for memory (fact list with delete), conversation history (journal entries, clear), project (pinned folder), and notes (destination, folders). |
| `scripts/generate-brand-assets.swift` | ~480 | Draws every brand asset from one geometry: the AppIcon PNGs (16-1024, with simplified waves at 64 px and below), `branding/heysona-mark.svg`, and `branding/heysona-logo-light.png` / `-dark.png`. Run from the repo root with `swift scripts/generate-brand-assets.swift`; never hand-edit the generated files. |
| `ScreenDrawingAnnotations.swift` | ~330 | Drawing tags: model, parser (pixel to display-point conversion), system prompt section, and the animated SwiftUI overlay rendering (circles, boxes, arrows, underlines, labels). |
| `StepByStepGuidance.swift` | ~200 | `[STEP]` tag parser (spoken-text offsets per step, pixel to display/global conversion), timing from ElevenLabs character timestamps, and the system prompt section. |
| `VisualExplanationSession.swift` | ~700 | One visual explanation: `[VISUAL]` tag parsing, streaming scene generation from Claude (JSON Lines), concepts line, step-by-step narration synced with the window, and the scene authoring prompt (simple English, analogies, CS/math/ML playbook). |
| `ExplanationLibraryStore.swift` | ~260 | Saves, lists, loads, and deletes finished visual explanations (scene JSON Lines and concepts) in Application Support; learned-topics list and concept map graph. |
| `VisualExplainerPanelManager.swift` | ~255 | Floating explainer window with a WKWebView; loads the bundled renderer page, queues commands until it's ready, sends scenes/steps (validated as JSON objects), relays page messages. |
| `VisualExplainer.bundle/` | — | Renderer page (`visual-explainer.html`), renderer (`visual-explainer.js`, ~2,400 lines, layout self-check, concept map view, expression parser and sliders, scene format documented at top), `three.min.js` + license, `katex/` (KaTeX script, stylesheet, fonts, license), and the rocket engine demo scene. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `APIKeyKeychainStore.swift` | ~135 | Reads and saves the Anthropic, AssemblyAI, and ElevenLabs API keys in the macOS Keychain. |
| `APIKeySetupPrompt.swift` | ~50 | On launch, shows an alert asking for any API key not yet saved in the Keychain. |
| `SettingsWindowManager.swift` | ~60 | Creates and shows the Settings window (titled `NSWindow` hosting `SettingsView`). |
| `SettingsView.swift` | ~430 | Settings UI: API keys, ElevenLabs voice picker with preview, Visuals toggles (draw on screen, step-by-step guidance, guided mode, visual explanations + rocket demo, captions), Mac actions toggle, memory/project/notes sections, Claude model, and spoken-reply toggle. Its layout helpers (`settingsCard`, `settingsSectionTitle`, `SettingsCapsuleButton`) are shared. |

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
