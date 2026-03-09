## CodeNotifier

CodeNotifier is an OpenCode plugin and companion binary that surfaces permission requests as native desktop toasts, allowing you to approve or deny actions (like shell, file, read, and task permissions) without leaving your editor.

### Quick start

- **Build binary**: Run `./build.sh` to produce the `opencode-toast` binary.
- **Install plugin**: Copy `plugin.ts` into your OpenCode plugins directory (for example `~/.config/opencode/plugins/toast.ts`).
- **Configure path**: Ensure the binary is on your `PATH` or set `CODENOTIFIER_BIN` to its full path.

### Requirements

- **Runtime**: Bun (for the plugin host).
- **OS**: macOS with notification support.
