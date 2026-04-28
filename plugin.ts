/*
  Plugin for Opencode

  ~/.config/opencode/plugins/toast.ts

  [!important]
  This assumes the toast binary is in the same directory as the plugin.
 */

import type { Plugin } from "@opencode-ai/plugin";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync } from "node:fs";
import { text } from "node:stream/consumers";

// CHANGE THIS IF YOU MOVE THE BINARY
const bin = process.env.CODENOTIFIER_BIN ?? `opencode-toast`;

type PermissionAsked = {
  id: string;
  sessionID: string;
  permission: string;
  patterns: string[];
  metadata: Record<string, unknown>;
};

type PermissionReplied = {
  requestID?: string;
  permissionID?: string;
};

type ClientConfig = {
  fetch?: typeof fetch;
  headers?: HeadersInit;
};

type ClientWithConfig = {
  _client?: {
    getConfig?: () => ClientConfig;
  };
};

function trim(value: string, max = 140) {
  if (value.length <= max) return value;
  return value.slice(0, max - 1) + "…";
}

function pick(data: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const val = data[key];
    if (typeof val === "string" && val) return val;
  }
}

function title(permission: string) {
  switch (permission) {
    case "bash":
      return "Shell Permission";
    case "edit":
    case "write":
      return "File Permission";
    case "read":
    case "glob":
    case "grep":
      return "Read Permission";
    case "task":
      return "Agent Permission";
    default:
      return "OpenCode Permission";
  }
}

function subtitle(permission: string) {
  return permission.toUpperCase();
}

function line(
  data: Record<string, unknown>,
  permission: string,
  patterns: string[]
) {
  if (permission === "bash") {
    const cmd = pick(data, ["description", "command"]);
    if (cmd) return trim(cmd);
  }

  if (permission === "read") {
    const file = pick(data, ["filePath", "path"]);
    if (file) return `Read ${trim(file)}`;
  }

  if (permission === "edit") {
    const file = pick(data, ["filepath", "filePath", "path"]);
    if (file) return `Edit ${trim(file)}`;
  }

  if (permission === "write") {
    const file = pick(data, ["filePath", "path"]);
    if (file) return `Write ${trim(file)}`;
  }

  if (permission === "glob" || permission === "grep") {
    const pat = pick(data, ["pattern"]);
    if (pat) return `${permission} ${trim(pat)}`;
  }

  if (permission === "webfetch") {
    const url = pick(data, ["url"]);
    if (url) return trim(url);
  }

  if (permission === "task") {
    const type = pick(data, ["subagent_type"]);
    const desc = pick(data, ["description"]);
    if (type && desc) return `${type}: ${trim(desc)}`;
    if (desc) return trim(desc);
  }

  if (patterns.length) return trim(patterns.join(", "));
  return trim(permission);
}

function legacyReply(out: string) {
  if (out === "Allow") return "allow" as const;
  return "deny" as const;
}

async function toast(
  id: string,
  processes: Map<string, { kill: () => boolean }>,
  permission: string,
  data: Record<string, unknown>,
  patterns: string[]
) {
  const cmd = [
    bin,
    "--title",
    title(permission),
    "--subtitle",
    subtitle(permission),
    "--message",
    line(data, permission, patterns),
    "--actions",
    "Deny,Allow",
    "--roles",
    "neutral,primary",
    "--tone",
    "info",
    "--sound",
    "Bottle",
    "--timeout",
    "0",
  ];

  const proc = spawn(cmd[0], cmd.slice(1), {
    stdio: ["ignore", "pipe", "ignore"],
  });

  processes.set(id, proc);
  const closed = once(proc, "close");

  try {
    const out = await text(proc.stdout);
    await closed;

    // If we were killed externally (replied event), the map entry would be gone
    if (!processes.has(id)) return null;

    return out.trim();
  } catch {
    return null;
  } finally {
    processes.delete(id);
  }
}

export const NotificationPlugin: Plugin = async (pluginInput) => {
  const ok = existsSync(bin);
  const processes = new Map<string, { kill: () => boolean }>();

  return {
    event: async ({ event }) => {
      /**
       * Permission responded in the tui, kill the toast
       */
      if (event.type === "permission.replied") {
        const props = event.properties as PermissionReplied;
        const id = props.requestID ?? props.permissionID;
        if (!id) return;

        const proc = processes.get(id);
        if (proc) {
          processes.delete(id);
          proc.kill();
        }
        return;
      }

      /**
       * Permission Ask
       */
      if ((event.type as string) === "permission.asked") {
        if (!ok) return;
        const props = event.properties as PermissionAsked;
        if (!props || !props.id) return;

        const out = await toast(
          props.id,
          processes,
          props.permission,
          props.metadata ?? {},
          props.patterns ?? []
        );

        if (out === null) return;

        const reply = legacyReply(out) === "allow" ? "once" : "reject";

        const url = new URL(
          `permission/${props.id}/reply`,
          pluginInput.serverUrl
        );
        url.searchParams.set("directory", pluginInput.directory);

        // Reuse OpenCode's injected fetch config; desktop requires its auth header.
        const config = (
          pluginInput.client as unknown as ClientWithConfig
        )._client?.getConfig?.();
        const customFetch = config?.fetch ?? fetch;
        const headers = new Headers(config?.headers);
        headers.set("Content-Type", "application/json");

        await customFetch(
          new Request(url.toString(), {
            method: "POST",
            headers,
            body: JSON.stringify({ reply }),
          })
        ).catch(() => {});
      }
    },
  };
};

export default NotificationPlugin;
