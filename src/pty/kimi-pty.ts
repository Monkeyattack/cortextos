import { join } from 'path';
import { AgentPTY } from './agent-pty.js';
import type { AgentConfig, CtxEnv } from '../types/index.js';

const KIMI_BINARY_DIR = '/home/claude-dev/.kimi-code/bin';
// kimi-code shows its model/brand name on startup; 'kimi' appears in the TUI header.
// If bootstrap detection times out (20s backstop), the agent still runs — adjust this
// pattern if kimi's actual startup text differs.
const KIMI_BOOTSTRAP_PATTERN = 'kimi';

/**
 * PTY wrapper for Kimi agents (Moonshot AI kimi-code CLI).
 *
 * kimi-code has the same CLI shape as Claude Code:
 *   kimi                  → fresh TUI session
 *   kimi --continue       → resume previous session
 *   kimi --yolo           → auto-approve tool calls (set in config.toml)
 *
 * The adapter reuses AgentPTY's injection and output-logging path. It only
 * overrides the binary name, args, and PATH so the daemon resolves the kimi
 * binary instead of claude.
 */
export class KimiPTY extends AgentPTY {
  constructor(env: CtxEnv, config: AgentConfig, logPath?: string) {
    super(env, config, logPath, KIMI_BOOTSTRAP_PATTERN);
  }

  protected getBinaryName(): string {
    return join(KIMI_BINARY_DIR, 'kimi');
  }

  protected buildClaudeArgs(mode: 'fresh' | 'continue', _prompt: string): string[] {
    const args: string[] = [];
    if (mode === 'continue') {
      args.push('--continue');
    }
    // --yolo: auto-approve regular tool calls (mirrors config.toml default_permission_mode)
    args.push('--yolo');
    if (this.config.model) {
      args.push('--model', this.config.model);
    }
    return args;
  }

  protected getTrustKeystrokes(): string {
    // kimi's trust dialog default selection is "Don't trust" (exits).
    // Up-arrow moves to "Trust this folder", then Enter confirms.
    return '\x1b[A\r';
  }

  protected customizeEnv(env: Record<string, string>): void {
    // Prepend kimi binary dir to PATH so any kimi sub-invocations resolve correctly.
    env['PATH'] = `${KIMI_BINARY_DIR}:${env['PATH'] || process.env.PATH || ''}`;
    // Point kimi-code at its own config directory.
    env['KIMI_CONFIG_DIR'] = '/home/claude-dev/.kimi-code';
    // Prevent kimi-code from defaulting to Anthropic/Claude when ANTHROPIC_API_KEY
    // is present in the shell environment. kimi-code should use Moonshot (config.toml).
    delete env['ANTHROPIC_API_KEY'];
    delete env['CLAUDE_CODE_OAUTH_TOKEN'];
  }
}
