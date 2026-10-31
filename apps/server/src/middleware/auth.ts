import { getAuth } from "@clerk/hono";
import type { Context, Next } from "hono";
import type { AppContext } from "../types";

export function requireAuth(c: Context<AppContext>, next: Next) {
  const { userId } = getAuth(c);

  if (!userId) {
    return c.json({ error: "Unauthorized" }, 401);
  }

  return next();
}
