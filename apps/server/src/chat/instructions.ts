export function shouldUseAppIntegrationTools(request: string | undefined): boolean {
  if (!request) {
    return true;
  }

  const text = request.toLowerCase();
  const screenOnlyIntent = /\b(point|pointing|cursor|coordinate|coordinates|screen|screenshot|show me where|where do i click|where should i click|highlight|look at|see on my screen|ui|button|menu|window|click)\b/.test(text);
  const explicitAppIntent = /\b(notion|gmail|email|slack|calendar|github|gitlab|google drive|drive|docs|sheets|slides|jira|linear|trello|asana|clickup|monday|airtable|hubspot|salesforce|pipedrive|zendesk|intercom|discord|outlook|onedrive|dropbox|shopify|stripe|quickbooks|xero|zoom|calendly|confluence|canva|youtube|twitter|linkedin|facebook|spotify|whatsapp|zoho|posthog)\b/.test(text);
  const externalActionIntent = /\b(send|create|update|delete|archive|schedule|invite|message|post|upload|download|search my|find my|add to|save to|move|rename)\b/.test(text);

  // Screen navigation and coordinate requests should use pointing tags, not Composio app tools.
  return !screenOnlyIntent || explicitAppIntent || externalActionIntent;
}

export function appToolkitsMentionedInRequest(request: string | undefined): string[] {
  if (!request) {
    return [];
  }

  const text = request.toLowerCase();
  const matches: string[] = [];
  const add = (toolkit: string) => {
    if (!matches.includes(toolkit)) {
      matches.push(toolkit);
    }
  };

  if (/\bnotion\b/.test(text)) add("notion");
  if (/\bgoogle\s*calendar\b|\bcalendar\b/.test(text)) add("googlecalendar");
  if (/\bgoogle\s*docs?\b|\bdocs?\b|\bdocument\b/.test(text)) add("googledocs");
  if (/\bgoogle\s*drive\b|\bdrive\b/.test(text)) add("googledrive");
  if (/\bgoogle\s*sheets?\b|\bsheets?\b|\bspreadsheet\b/.test(text)) add("googlesheets");
  if (/\bgoogle\s*slides?\b|\bslides?\b|\bpresentation\b/.test(text)) add("googleslides");

  return matches;
}

export function withPointerToolInstructions(system: string | undefined): string | undefined {
  const instructions = `

pointing tags:
- When pointing would help, write [POINT:x,y:label] directly in your response at the exact moment the cursor should point there.
- For navigation help, include one [POINT:...] tag for EACH separate UI target, in the order the user should look at them.
- Put the short spoken instruction for each target immediately after that target's tag. Example: [POINT:120,40:font] choose the font here. [POINT:220,40:size] then change the size here.
- Do not combine two targets into one tag. Do not stop after the first target when the user asked for more than one.
- If the element is on a different screen, append :screenN, like [POINT:400,300:terminal:screen2].
- If pointing would not help, do not include a point tag.
- Coordinates must use the screenshot pixel coordinate space: origin top-left, x rightward, y downward.
- Keep labels short because they appear next to the cursor.`;

  return system ? `${system}${instructions}` : instructions.trim();
}

export function withAgentInstructions(
  system: string | undefined,
  context: { hasAppTools?: boolean; activeToolkits?: string[]; latestUserRequest?: string } = {}
): string {
  const activeToolkitsText = context.activeToolkits?.length ? context.activeToolkits.join(", ") : "none";
  const latestUserRequestText = context.latestUserRequest ? `\n- Current user request to execute exactly: ${context.latestUserRequest}` : "";
  const instructions = `

app integrations:
- ${context.hasAppTools ? `Connected app toolkits available: ${activeToolkitsText}.` : "No connected app tools are available in this conversation."}${latestUserRequestText}
- App integration tools are only for external app/data actions like creating, editing, searching, sending, scheduling, uploading, or organizing content inside connected services.
- Do not use app integration tools for screen pointing, cursor movement, coordinates, visual navigation, UI explanations, or questions about what is visible on screen. For those, use pointing tags only.
- If app integration tools are available and the user asks to create, edit, search, send, or organize content in a connected app, use the matching tools immediately.
- For multi-step app tasks, keep calling tools until the requested task is actually complete; do not stop after only searching or opening context.
- Treat the user's latest message as the source of truth for the current app task. Do not reuse titles, recipients, project names, IDs, URLs, or other parameters from earlier turns unless the latest user request explicitly refers to them.
- Use the user's requested names/content/recipients/dates exactly. Do not substitute values from examples, screenshots, docs, or previous tool errors.
- Before creating, updating, sending, moving, or deleting in any external app, identify the required target/container/resource fields from the tool schema. If a required resource ID/container/account/channel/folder/calendar/database/page/repository/document is missing, use available search/list/get tools for that same toolkit to discover valid resources and prefer returned stable IDs/UUIDs over human-readable titles or names.
- Never invent parent folders, database names, channel names, recipient addresses, calendar IDs, repository names, file paths, document IDs, issue numbers, or other external resource identifiers. Search/list first; if you still cannot determine the required resource unambiguously, ask one concise clarification question.
- If a tool returns an error or says the action was not completed, do not claim success. Read the error, use another appropriate search/list/get tool to fix the missing/invalid parameter, and retry when safe. Only give up when no safe recovery is possible.
- If a tool returns multiple possible matches, choose only when one clearly matches the user's request; otherwise ask for clarification.
- For multi-step app tasks, continue until the final requested state is true, not merely until one tool has been called.
- After a successful app action, briefly confirm exactly what changed and where.
- If the needed app tools are not available, tell the user to connect that app from the Agents tab.`;

  return system ? `${system}${instructions}` : instructions.trim();
}
