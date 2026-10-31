import type { AssistantContent, ModelMessage, UserContent } from "ai";
import type { ChatContentBlock, ChatMessage } from "../types";

export function toGatewayModelId(model: string | undefined): string {
  if (!model) {
    return "openai/gpt-5.4-mini";
  }

  if (model.includes("/")) {
    return model;
  }

  return model;
}

export function toModelMessages(chatMessages: ChatMessage[]): ModelMessage[] {
  return chatMessages.map((chatMessage): ModelMessage => {
    if (chatMessage.role === "user") {
      return {
        role: "user",
        content: toUserMessageContent(chatMessage.content),
      };
    }

    return {
      role: "assistant",
      content: toAssistantMessageContent(chatMessage.content),
    };
  });
}

export function latestUserText(chatMessages: ChatMessage[]): string | undefined {
  const latestUserMessage = chatMessages.findLast((message) => message.role === "user");
  if (!latestUserMessage) {
    return undefined;
  }

  if (typeof latestUserMessage.content === "string") {
    return latestUserMessage.content.trim() || undefined;
  }

  return latestUserMessage.content
    .filter((block) => block.type === "text")
    .map((block) => block.text.trim())
    .filter(Boolean)
    .join("\n") || undefined;
}

function toUserMessageContent(content: string | ChatContentBlock[]): UserContent {
  if (typeof content === "string") {
    return content;
  }

  return content.map((contentBlock) => {
    if (contentBlock.type === "text") {
      return { type: "text", text: contentBlock.text };
    }

    return {
      type: "image",
      image: contentBlock.image,
      mediaType: contentBlock.mediaType,
    };
  });
}

function toAssistantMessageContent(content: string | ChatContentBlock[]): AssistantContent {
  if (typeof content === "string") {
    return content;
  }

  return content
    .filter((contentBlock) => contentBlock.type === "text")
    .map((contentBlock) => ({ type: "text", text: contentBlock.text }));
}
