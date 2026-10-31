import { clerkMiddleware } from "@clerk/hono";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { requireAuth } from "./middleware/auth";
import { handleChat } from "./routes/chat";
import {
  handleToolkitConnect,
  handleToolkitDisconnect,
  handleToolkitStatuses,
} from "./routes/integrations";
import { handleTranscribeToken } from "./routes/transcribe";
import { handleTTS } from "./routes/tts";
import type { AppContext } from "./types";

const app = new Hono<AppContext>();

app.use(
  "*",
  cors({
    origin: "*",
    allowHeaders: ["Authorization", "Content-Type"],
    allowMethods: ["DELETE", "GET", "POST", "OPTIONS"],
  })
);

app.use("/chat", clerkMiddleware());
app.use("/integrations/*", clerkMiddleware());
app.use("/tts", clerkMiddleware());
app.use("/transcribe-token", clerkMiddleware());

app.post("/chat", requireAuth, (c) => handleChat(c));
app.post("/integrations/statuses", requireAuth, (c) => handleToolkitStatuses(c));
app.post("/integrations/:toolkit/connect", requireAuth, (c) => handleToolkitConnect(c));
app.delete("/integrations/:toolkit/disconnect", requireAuth, (c) => handleToolkitDisconnect(c));
app.post("/tts", requireAuth, (c) => handleTTS(c.req.raw, c.env));
app.post("/transcribe-token", requireAuth, (c) => handleTranscribeToken(c.env));

app.notFound((c) => c.text("Not found", 404));

app.onError((error, c) => {
  console.error(`[${new URL(c.req.url).pathname}] Unhandled error:`, error);
  return c.json({ error: String(error) }, 500);
});

export default app;
