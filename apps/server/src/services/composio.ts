import { Composio } from "@composio/core";
import { VercelProvider } from "@composio/vercel";
import type { Env } from "../types";

export function makeComposio(env: Env) {
  const apiKey = env.COMPOSIO_API_KEY?.trim();
  if (!apiKey) {
    return undefined;
  }

  return new Composio({
    apiKey,
    provider: new VercelProvider({ strict: true }),
  });
}

export async function getToolsForUser(env: Env, userId: string, requestedToolkits: string[] = []) {
  const composio = makeComposio(env);
  if (!composio) {
    return undefined;
  }

  const accounts = await listConnectedAccounts(composio, {
    userIds: [userId],
    statuses: ["ACTIVE"],
    limit: 100,
  }).catch((error) => {
    console.error("Composio connected account lookup failed", composioErrorSummary(error));
    return [];
  });
  const activeToolkits = Array.from(
    new Set(accounts.map((account) => account.toolkit.slug))
  );

  if (activeToolkits.length === 0) {
    return undefined;
  }

  const requested = new Set(requestedToolkits);
  const toolkitsToLoad = requested.size > 0
    ? activeToolkits.filter((toolkit) => requested.has(toolkit))
    : activeToolkits;

  if (toolkitsToLoad.length === 0) {
    return { tools: undefined, activeToolkits };
  }

  const tools = await composio.tools.get(
    userId,
    {
      toolkits: toolkitsToLoad,
      limit: Math.max(100, toolkitsToLoad.length * 100),
    },
    {
      modifySchema: ({ schema }) => ({
        ...schema,
        description: addToolUseProtocol(schema.description),
      }),
    }
  );

  return { tools, activeToolkits: toolkitsToLoad };
}

export async function listConnectedAccounts(
  composio: NonNullable<ReturnType<typeof makeComposio>>,
  query: Parameters<typeof composio.connectedAccounts.list>[0] = {}
) {
  const items: Awaited<ReturnType<typeof composio.connectedAccounts.list>>["items"] = [];
  let cursor: string | null | undefined;

  do {
    const page = await composio.connectedAccounts.list({
      ...query,
      cursor,
      limit: query.limit ?? 100,
    });
    items.push(...page.items);
    cursor = page.nextCursor;
  } while (cursor);

  return items;
}

export function composioErrorSummary(error: unknown) {
  if (!(error instanceof Error)) {
    return { message: String(error) };
  }

  const details = error as Error & { status?: number; error?: unknown; errorId?: string };
  return {
    name: details.name,
    message: details.message,
    status: details.status,
    errorId: details.errorId,
    error: details.error,
  };
}

export function isComposioAuthError(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "status" in error && (error as { status?: unknown }).status === 401);
}

function addToolUseProtocol(description: string | undefined): string {
  const protocol = "Tool-use protocol: use this external app tool only when the user explicitly asks to act in this app/toolkit or manage external app data. Do not use app tools for screen pointing, cursor movement, coordinates, visual navigation, UI help, or general conversation. Use exact user-provided values; do not invent external resource IDs/names; search/list/get first when required IDs or containers are missing; retry safely after recoverable errors; only report success when the tool result is successful.";
  return description ? `${description}\n\n${protocol}` : protocol;
}
