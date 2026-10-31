import type { Env } from "../types";

const GRADIUM_TTS_URL = "https://api.gradium.ai/api/post/speech/tts";
const DEFAULT_GRADIUM_TTS_MODEL = "default";
const DEFAULT_GRADIUM_TTS_VOICE_ID = "YTpq7expH9539ERJ";

export async function handleTTS(request: Request, env: Env): Promise<Response> {
  const ttsRequestBody = (await request.json()) as { text?: string };
  const textToSpeak = ttsRequestBody.text?.trim();

  if (!textToSpeak) {
    return new Response(JSON.stringify({ error: "Missing text" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  if (!env.GRADIUM_API_KEY) {
    return new Response(JSON.stringify({ error: "Missing GRADIUM_API_KEY" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  try {
    const wavAudio = await synthesizeWithGradiumRest({
      apiKey: env.GRADIUM_API_KEY,
      modelName: env.GRADIUM_TTS_MODEL ?? DEFAULT_GRADIUM_TTS_MODEL,
      voiceId: env.GRADIUM_TTS_VOICE_ID ?? DEFAULT_GRADIUM_TTS_VOICE_ID,
      text: textToSpeak,
    });

    return new Response(wavAudio, {
      status: 200,
      headers: {
        "content-type": "audio/wav",
      },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Gradium TTS request failed";
    console.error(`[/tts] Gradium TTS error: ${message}`);
    return new Response(JSON.stringify({ error: message }), {
      status: 502,
      headers: { "content-type": "application/json" },
    });
  }
}

async function synthesizeWithGradiumRest({
  apiKey,
  modelName,
  voiceId,
  text,
}: {
  apiKey: string;
  modelName: string;
  voiceId: string;
  text: string;
}): Promise<ArrayBuffer> {
  const response = await fetch(GRADIUM_TTS_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": apiKey,
    },
    body: JSON.stringify({
      text,
      voice_id: voiceId,
      model_name: modelName,
      output_format: "wav",
      only_audio: true,
    }),
  });

  if (!response.ok) {
    throw new Error(await getGradiumErrorMessage(response));
  }

  return response.arrayBuffer();
}

async function getGradiumErrorMessage(response: Response): Promise<string> {
  const responseText = await response.text();
  if (!responseText) {
    return `Gradium TTS request failed with status ${response.status}`;
  }

  try {
    const responseJson = JSON.parse(responseText) as { error?: unknown; message?: unknown };
    const errorMessage = responseJson.error ?? responseJson.message;
    if (typeof errorMessage === "string" && errorMessage.length > 0) {
      return errorMessage;
    }
  } catch {
    // Gradium may return plain text errors; fall through to include the body.
  }

  return `Gradium TTS request failed with status ${response.status}: ${responseText}`;
}
