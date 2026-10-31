# heySona

Hi, this is heySona.

Built by [Shujan Shaikh](https://x.com/shujanshaikh).

heySona started as a clone of [Clicky](https://github.com/farzaa/clicky), a project by [Farza](https://x.com/FarzaTV). This repo takes that idea and turns it into a native macOS screen companion with authenticated cloud AI, speech, screen understanding, cursor pointing, and agent integrations for external apps like Notion, Google Docs, Gmail, Slack, GitHub, and more.

It's a buddy that lives on your Mac. You talk to it, it can see your screen, answer out loud, point at things, and help take action in the tools you connect.

## What it does

heySona is a macOS menu bar companion that you talk to with push-to-talk. It captures your screen, sends the visual context plus your transcript to an AI model, streams back an answer, speaks it out loud, and can point at UI elements with an on-screen cursor.

The backend runs as a Cloudflare Worker and handles the stuff you don't want shipped inside the app binary:

- authenticated chat streaming through the Vercel AI SDK AI Gateway
- AssemblyAI realtime transcription token generation
- Gradium text-to-speech proxying
- Composio-powered agent integrations for connected apps like Notion, Google Docs, Gmail, Slack, GitHub, and more
- Clerk authentication for the macOS app and server routes

## Architecture

Short version: heySona is a native Swift/AppKit menu bar app backed by a Hono Cloudflare Worker API.

The app handles the macOS experience: menu bar UI, push-to-talk, screen capture, voice playback, cursor pointing, and auth callbacks. The Worker handles authenticated API access, model streaming, transcription tokens, TTS proxying, and external-tool agent integrations.

## Project structure

```txt
apps/
  macos/    Native Swift/AppKit macOS app
  server/   Hono Cloudflare Worker API
packages/
  config/   Shared TypeScript config
```

## Agent integrations with Composio

heySona includes agent integrations through Composio. Users can connect external apps such as Notion, Google Docs, Gmail, Slack, GitHub, and other Composio-supported toolkits, then ask heySona to take action in those apps.

The server uses `@composio/core` with the Composio Vercel provider. When a signed-in user asks heySona to work with an external app, the server checks that user's active Composio connected accounts and loads the relevant toolkit tools into the AI SDK `streamText` call.

That means the AI agent only gets connected-app tools when the user explicitly asks for external-app work, like:

- creating a Notion page
- finding or summarizing a Google Doc
- drafting something in Gmail
- updating information in a connected workspace
- working with Slack, GitHub, or another connected toolkit

Integration endpoints:

- `POST /integrations/statuses` — check whether requested toolkits are connected
- `POST /integrations/:toolkit/connect` — create a Composio connection link
- `DELETE /integrations/:toolkit/disconnect` — remove connected accounts for a toolkit

Composio OAuth returns to the macOS app using:

```txt
heysona://composio/callback
```

Make sure this callback/deep-link scheme is allowed wherever your Composio integration setup requires redirect URLs.

## Prerequisites

You'll want:

- macOS with Xcode installed
- Node.js / pnpm for the Worker and monorepo tooling
- A Cloudflare account for the Worker
- API keys for AI Gateway, Clerk, AssemblyAI, Gradium, and Composio

## 1. Install dependencies

From the repo root:

```bash
pnpm install
```

## 2. Configure the Cloudflare Worker

The Worker lives in `apps/server`.

For local development, create `apps/server/.dev.vars`:

```bash
AI_GATEWAY_API_KEY=...
CLERK_SECRET_KEY=...
ASSEMBLYAI_API_KEY=...
GRADIUM_API_KEY=...
COMPOSIO_API_KEY=...

# Optional; defaults are also in wrangler.toml
GRADIUM_TTS_MODEL=default
GRADIUM_TTS_VOICE_ID=YTpq7expH9539ERJ
```

For deployed Workers, add secrets with Wrangler:

```bash
cd apps/server
npx wrangler secret put AI_GATEWAY_API_KEY
npx wrangler secret put CLERK_SECRET_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put GRADIUM_API_KEY
npx wrangler secret put COMPOSIO_API_KEY
```

Notes:

- `AI_GATEWAY_API_KEY` is used by `createGateway()` for model calls.
- `CLERK_SECRET_KEY` is required by `@clerk/hono` to authenticate protected routes.
- `ASSEMBLYAI_API_KEY` is used by `/transcribe-token`.
- `GRADIUM_API_KEY` is used by `/tts`.
- `COMPOSIO_API_KEY` enables connected-account lookup, toolkit auth links, and AI tools.

## 3. Run the Worker locally

```bash
pnpm run dev:server
```

The local Worker usually runs at:

```txt
http://localhost:8787
```

For deployed Workers, use:

```bash
pnpm run deploy:server
```

## 4. Configure the macOS app

The macOS app reads these values from Xcode build settings injected into `apps/macos/heySona/Info.plist`:

```txt
HEYSONA_SERVER_BASE_URL   # e.g. http://localhost:8787 or your deployed Worker URL
CLERK_PUBLISHABLE_KEY   # Clerk publishable key matching the same Clerk app as the server
CLERK_CALLBACK_SCHEME   # usually heysona
CLERK_REDIRECT_URL      # usually heysona://callback
```

Authentication depends on these being aligned with Clerk:

1. The macOS app uses `CLERK_PUBLISHABLE_KEY` to initialize ClerkKit.
2. OAuth redirects back to `CLERK_REDIRECT_URL` using `CLERK_CALLBACK_SCHEME`.
3. `Info.plist` registers the same URL scheme under `CFBundleURLTypes`.
4. The server validates requests with `CLERK_SECRET_KEY` from the same Clerk application.

For local development, point the app at the Worker dev server:

```txt
HEYSONA_SERVER_BASE_URL=http://localhost:8787
```

If `HEYSONA_SERVER_BASE_URL` is unset, the app falls back to `http://localhost:8787`.

## 5. Open in Xcode and run

Open the macOS project:

```bash
open apps/macos/heySona.xcodeproj
```

In Xcode:

1. Select the `heySona` scheme.
2. Set your signing team under Signing & Capabilities.
3. Make sure the required build settings are present.
4. Hit Cmd + R.

heySona runs as a menu bar app. Click the menu bar icon, sign in, grant the permissions it asks for, and you're good.

## Development

Run all JS apps through Turborepo:

```bash
pnpm run dev
```

Run only the Worker API:

```bash
pnpm run dev:server
```

Open the macOS app from `apps/macos/heySona.xcodeproj` in Xcode and run the `heySona` scheme.

## Scripts

- `pnpm run dev` — start all configured apps in development mode
- `pnpm run build` — build the monorepo
- `pnpm run check-types` — TypeScript checks
- `pnpm run dev:server` — start the Cloudflare Worker locally
- `pnpm run deploy:server` — deploy the Worker

## Go crazy

Tweak the details, overhaul the design, or construct something uniquely yours
