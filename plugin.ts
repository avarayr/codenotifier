/*
  Plugin for Opencode

  ~/.config/opencode/plugins/toast.ts

  [!important]
  This assumes the toast binary is in the same directory as the plugin.
 */

import type { Plugin } from "@opencode-ai/plugin";

// CHANGE THIS IF YOU MOVE THE BINARY
const bin =
  Bun.env.CODENOTIFIER_BIN ??
  `/Users/mika/experiments/codenotifier/dist/opencode-toast`;

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
  processes: Map<string, any>,
  permission: string,
  data: Record<string, unknown>,
  patterns: string[]
) {
  const proc = Bun.spawn({
    cmd: [
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
    ],
    stdout: "pipe",
    stderr: "pipe",
  });

  processes.set(id, proc);

  try {
    const text = await new Response(proc.stdout).text();
    await proc.exited;

    // If we were killed externally (replied event), the map entry would be gone
    if (!processes.has(id)) return null;

    return text.trim();
  } catch (e) {
    return null;
  } finally {
    processes.delete(id);
  }
}

export const NotificationPlugin: Plugin = async (pluginInput) => {
  const ok = await Bun.file(bin).exists();
  const processes = new Map<string, any>();

  return {
    event: async ({ event }) => {
      /**
       * Permission responded in the tui, kill the toast
       */
      if (event.type === "permission.replied") {
        const props = event.properties as any;
        const id = props.requestID || props.permissionID;

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
        const props = event.properties as any;
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

        // @ts-expect-error - _client is protected but we need to access it
        const client = pluginInput.client._client ?? pluginInput.client.client;
        const customFetch = client?.getConfig?.()?.fetch;

        await customFetch?.(
          new Request(`/permission/${props.id}/reply`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ reply }),
          })
        ).catch((e) => {
          console.log("[plugin] fetch error:", e);
        });
      }
    },
  };
};

export default NotificationPlugin;
