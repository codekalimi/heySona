import { getAuth } from "@clerk/hono";
import type { Context } from "hono";
import { composioErrorSummary, isComposioAuthError, listConnectedAccounts, makeComposio } from "../services/composio";
import type { AppContext } from "../types";

export async function handleToolkitStatuses(c: Context<AppContext>): Promise<Response> {
  const { userId } = getAuth(c);
  if (!userId) {
    return c.json({ error: "Unauthorized" }, 401);
  }

  const body = await c.req.json().catch(() => ({})) as { toolkits?: unknown };
  const toolkits = Array.isArray(body.toolkits)
    ? [...new Set(body.toolkits.filter((toolkit): toolkit is string => typeof toolkit === "string").map(normalizedToolkitSlug).filter(Boolean))]
    : [];

  if (toolkits.length === 0) {
    return c.json({ configured: true, statuses: {} });
  }

  const composio = makeComposio(c.env);
  if (!composio) {
    return c.json({
      configured: false,
      statuses: Object.fromEntries(toolkits.map((toolkit) => [toolkit, { toolkit, connected: false, configured: false }])),
    });
  }

  const accounts = await listConnectedAccounts(composio, {
    userIds: [userId],
    toolkitSlugs: toolkits,
    limit: 100,
  }).catch((error) => {
    console.error("Composio status lookup failed", composioErrorSummary(error));
    if (isComposioAuthError(error)) {
      return undefined;
    }
    throw error;
  });

  if (!accounts) {
    return c.json({
      configured: false,
      error: "COMPOSIO_API_KEY is invalid or unauthorized",
      statuses: Object.fromEntries(toolkits.map((toolkit) => [toolkit, { toolkit, connected: false, configured: false, status: "AUTH_ERROR" }])),
    }, 502);
  }
  const accountByToolkit = new Map<string, (typeof accounts)[number]>();
  for (const account of accounts) {
    const existing = accountByToolkit.get(account.toolkit.slug);
    if (!existing || (existing.status !== "ACTIVE" && account.status === "ACTIVE")) {
      accountByToolkit.set(account.toolkit.slug, account);
    }
  }

  return c.json({
    configured: true,
    statuses: Object.fromEntries(toolkits.map((toolkit) => [toolkit, statusPayload(toolkit, accountByToolkit.get(toolkit))])),
  });
}

export async function handleToolkitConnect(c: Context<AppContext>): Promise<Response> {
  const { userId } = getAuth(c);
  if (!userId) {
    return c.json({ error: "Unauthorized" }, 401);
  }

  const toolkit = toolkitParam(c);
  const composio = makeComposio(c.env);
  if (!composio) {
    return c.json({ error: "COMPOSIO_API_KEY is not configured" }, 500);
  }

  const connection = await (async () => {
    const authConfigs = await composio.authConfigs.list({ toolkit });
    const authConfig = authConfigs.items[0] ?? await composio.authConfigs.create(toolkit);

    return composio.connectedAccounts.link(userId, authConfig.id, {
      callbackUrl: "heysona://composio/callback",
    });
  })().catch((error) => {
    console.error("Composio connection start failed", composioErrorSummary(error));
    if (isComposioAuthError(error)) {
      return undefined;
    }
    throw error;
  });

  if (!connection) {
    return c.json({ error: "COMPOSIO_API_KEY is invalid or unauthorized" }, 502);
  }

  return c.json({
    toolkit,
    redirectUrl: connection.redirectUrl,
    connectionRequestId: connection.id,
  });
}

export async function handleToolkitDisconnect(c: Context<AppContext>): Promise<Response> {
  const { userId } = getAuth(c);
  if (!userId) {
    return c.json({ error: "Unauthorized" }, 401);
  }

  const toolkit = toolkitParam(c);
  const composio = makeComposio(c.env);
  if (!composio) {
    return c.json({ error: "COMPOSIO_API_KEY is not configured" }, 500);
  }

  const accounts = await listConnectedAccounts(composio, {
    userIds: [userId],
    toolkitSlugs: [toolkit],
    limit: 100,
  }).catch((error) => {
    console.error("Composio disconnect lookup failed", composioErrorSummary(error));
    if (isComposioAuthError(error)) {
      return undefined;
    }
    throw error;
  });

  if (!accounts) {
    return c.json({ error: "COMPOSIO_API_KEY is invalid or unauthorized" }, 502);
  }

  const connectedAccounts = accounts.filter((account) => account.toolkit.slug === toolkit);

  await Promise.all(connectedAccounts.map((account) => composio.connectedAccounts.delete(account.id)));

  return c.json({
    toolkit,
    disconnected: true,
    deletedCount: connectedAccounts.length,
  });
}

function normalizedToolkitSlug(toolkit: string): string {
  return toolkit.trim().toLowerCase();
}

function statusPayload(toolkit: string, connectedAccount: { id: string; status?: string; toolkit: { slug: string } } | undefined) {
  return {
    toolkit,
    configured: true,
    connected: connectedAccount?.status === "ACTIVE",
    status: connectedAccount?.status ?? "NOT_CONNECTED",
    connectedAccountId: connectedAccount?.id,
  };
}

function toolkitParam(c: Context<AppContext>): string {
  const toolkit = c.req.param("toolkit");
  if (!toolkit) {
    throw new Error("Missing toolkit");
  }

  return normalizedToolkitSlug(toolkit);
}
