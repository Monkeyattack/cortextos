/**
 * `cortextos bus hook-session-start` is not a registered bus subcommand — it
 * exits with "unknown command". The agent settings template shipped a
 * SessionStart stanza invoking it, so every agent created from the template
 * carried a hook that could only ever fail. The template no longer emits it and
 * `bus fix-agent-settings` strips it from existing settings.json files.
 *
 * The subcommand is deliberately NOT implemented — the stanza is dead weight.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

import { busCommand, stripDeadSessionStartHook } from '../../../src/cli/bus';

const DEAD_COMMAND = 'cortextos bus hook-session-start';
const TEMPLATE_SETTINGS = join(__dirname, '../../../templates/agent/.claude/settings.json');

describe('agent settings template', () => {
  it('no longer emits the dead SessionStart hook', () => {
    const raw = readFileSync(TEMPLATE_SETTINGS, 'utf-8');
    expect(raw).not.toContain(DEAD_COMMAND);
    const settings = JSON.parse(raw);
    expect(settings.hooks.SessionStart).toBeUndefined();
    // The rest of the hook set is untouched.
    expect(Object.keys(settings.hooks)).toEqual(
      expect.arrayContaining(['PreToolUse', 'Stop', 'SessionEnd', 'PreCompact']),
    );
  });
});

describe('stripDeadSessionStartHook', () => {
  it('drops the SessionStart key when the dead hook was its only entry', () => {
    const settings = {
      hooks: {
        SessionStart: [{ hooks: [{ type: 'command', command: DEAD_COMMAND, timeout: 30 }] }],
        Stop: [{ hooks: [{ type: 'command', command: 'cortextos bus hook-idle-flag' }] }],
      },
    };
    expect(stripDeadSessionStartHook(settings)).toBe(true);
    expect(settings.hooks).not.toHaveProperty('SessionStart');
    expect(settings.hooks.Stop).toHaveLength(1);
  });

  it('preserves other SessionStart hooks alongside the dead one', () => {
    const settings = {
      hooks: {
        SessionStart: [{
          hooks: [
            { type: 'command', command: DEAD_COMMAND },
            { type: 'command', command: 'my-own-hook' },
          ],
        }],
      },
    };
    expect(stripDeadSessionStartHook(settings)).toBe(true);
    expect(settings.hooks.SessionStart).toEqual([
      { hooks: [{ type: 'command', command: 'my-own-hook' }] },
    ]);
  });

  it('is a no-op when the dead hook is absent', () => {
    const settings = { hooks: { SessionStart: [{ hooks: [{ command: 'my-own-hook' }] }] } };
    const before = JSON.stringify(settings);
    expect(stripDeadSessionStartHook(settings)).toBe(false);
    expect(JSON.stringify(settings)).toBe(before);
  });
});

describe('bus fix-agent-settings', () => {
  let root: string;
  let settingsPath: string;
  const savedEnv = { ...process.env };

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'ctx-fix-settings-'));
    settingsPath = join(root, 'orgs', 'acme', 'agents', 'alice', '.claude', 'settings.json');
    mkdirSync(join(root, 'orgs', 'acme', 'agents', 'alice', '.claude'), { recursive: true });
    writeFileSync(settingsPath, JSON.stringify({
      permissions: { allow: ['Bash', 'Read', 'Edit', 'Write', 'Glob', 'Grep', 'WebFetch',
        'WebSearch', 'ToolSearch', 'CronCreate', 'CronList', 'CronDelete', 'Skill', 'Agent'] },
      statusLine: { type: 'command', command: 'cortextos bus hook-context-status', refreshInterval: 60 },
      hooks: {
        SessionStart: [{ hooks: [{ type: 'command', command: DEAD_COMMAND, timeout: 30 }] }],
        Stop: [{ hooks: [{ type: 'command', command: 'cortextos bus hook-idle-flag' }] }],
      },
    }, null, 2) + '\n');
    // Scrub any inherited CTX_* so an agent session running the suite does not
    // leak its own agent resolution into resolveEnv().
    for (const key of Object.keys(process.env)) {
      if (key.startsWith('CTX_')) delete process.env[key];
    }
    process.env.CTX_FRAMEWORK_ROOT = root;
    process.env.CTX_PROJECT_ROOT = root;
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
    process.env = { ...savedEnv };
  });

  it('removes the dead SessionStart hook from an existing agent settings.json', async () => {
    await busCommand.parseAsync(['fix-agent-settings'], { from: 'user' });

    const patched = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    expect(patched.hooks).not.toHaveProperty('SessionStart');
    expect(patched.hooks.Stop).toHaveLength(1);
  });

  it('leaves the file untouched under --dry-run', async () => {
    const before = readFileSync(settingsPath, 'utf-8');
    await busCommand.parseAsync(['fix-agent-settings', '--dry-run'], { from: 'user' });
    expect(readFileSync(settingsPath, 'utf-8')).toBe(before);
  });
});
