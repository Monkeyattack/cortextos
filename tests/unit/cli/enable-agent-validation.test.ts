/**
 * Regression tests for the multi-bug batch PR:
 *
 * - BUG-035: discoverProjectRoot() — cwd-independent project root discovery
 * - BUG-013: readEnabledAgents() — defensive validation + backup of corrupt files
 *
 * The point of these tests is to lock in the contract: enable's CLI must work
 * from any cwd, and corrupt JSON must NEVER be silently destroyed.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import {
  discoverProjectRoot,
  readEnabledAgents,
  isBusOnlyAgent,
  BUS_ONLY_TOKEN,
} from '../../../src/cli/enable-agent';

describe('BUG-035 + BUG-013: enable-agent validation', () => {
  let tmpHome: string;
  const origHome = process.env.HOME;
  const origFw = process.env.CTX_FRAMEWORK_ROOT;
  const origPr = process.env.CTX_PROJECT_ROOT;

  beforeEach(() => {
    tmpHome = mkdtempSync(join(tmpdir(), 'cortextos-batch-'));
    process.env.HOME = tmpHome;
    delete process.env.CTX_FRAMEWORK_ROOT;
    delete process.env.CTX_PROJECT_ROOT;
  });

  afterEach(() => {
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
    if (origFw === undefined) delete process.env.CTX_FRAMEWORK_ROOT;
    else process.env.CTX_FRAMEWORK_ROOT = origFw;
    if (origPr === undefined) delete process.env.CTX_PROJECT_ROOT;
    else process.env.CTX_PROJECT_ROOT = origPr;
    rmSync(tmpHome, { recursive: true, force: true });
  });

  describe('discoverProjectRoot (BUG-035)', () => {
    it('honors CTX_FRAMEWORK_ROOT when set', () => {
      process.env.CTX_FRAMEWORK_ROOT = '/some/explicit/path';
      expect(discoverProjectRoot()).toBe('/some/explicit/path');
    });

    it('falls back to CTX_PROJECT_ROOT when CTX_FRAMEWORK_ROOT is unset', () => {
      process.env.CTX_PROJECT_ROOT = '/legacy/path';
      expect(discoverProjectRoot()).toBe('/legacy/path');
    });

    it('discovers ~/cortextos when both env vars are unset and the canonical install exists', () => {
      // Create a fake ~/cortextos with an orgs/ dir (the canonical marker)
      mkdirSync(join(tmpHome, 'cortextos', 'orgs'), { recursive: true });
      expect(discoverProjectRoot()).toBe(join(tmpHome, 'cortextos'));
    });

    it('also recognizes ~/cortextos via legacy agents/ dir', () => {
      mkdirSync(join(tmpHome, 'cortextos', 'agents'), { recursive: true });
      expect(discoverProjectRoot()).toBe(join(tmpHome, 'cortextos'));
    });

    it('falls back to process.cwd() when nothing else applies (legacy behavior preserved)', () => {
      // No env vars, no ~/cortextos at all
      expect(discoverProjectRoot()).toBe(process.cwd());
    });
  });

  describe('readEnabledAgents (BUG-013)', () => {
    function setupConfigFile(instanceId: string, content: string): string {
      const configDir = join(tmpHome, '.cortextos', instanceId, 'config');
      mkdirSync(configDir, { recursive: true });
      const path = join(configDir, 'enabled-agents.json');
      writeFileSync(path, content);
      return path;
    }

    it('returns {} when the file does not exist (legitimate empty state)', () => {
      const result = readEnabledAgents('default');
      expect(result).toEqual({});
    });

    it('returns the parsed object on valid JSON', () => {
      setupConfigFile('default', '{"commander":{"enabled":true,"org":"testorg"}}');
      const result = readEnabledAgents('default');
      expect(result).toEqual({ commander: { enabled: true, org: 'testorg' } });
    });

    it('backs up corrupt JSON instead of silently returning {}', () => {
      const path = setupConfigFile('default', 'this is not json{{{');
      const result = readEnabledAgents('default');
      expect(result).toEqual({});

      // The corrupt file should be backed up, not destroyed
      const backups = readdirSync(join(tmpHome, '.cortextos', 'default', 'config'))
        .filter(f => f.startsWith('enabled-agents.json.broken-'));
      expect(backups.length).toBeGreaterThan(0);

      // The original file is still there (caller may decide to overwrite)
      expect(existsSync(path)).toBe(true);
    });

    it('rejects array values (wrong shape) and backs them up', () => {
      setupConfigFile('default', '["this", "should", "be", "an", "object"]');
      const result = readEnabledAgents('default');
      expect(result).toEqual({});

      const backups = readdirSync(join(tmpHome, '.cortextos', 'default', 'config'))
        .filter(f => f.startsWith('enabled-agents.json.broken-'));
      expect(backups.length).toBeGreaterThan(0);
    });

    it('rejects null values and backs them up', () => {
      setupConfigFile('default', 'null');
      const result = readEnabledAgents('default');
      expect(result).toEqual({});

      const backups = readdirSync(join(tmpHome, '.cortextos', 'default', 'config'))
        .filter(f => f.startsWith('enabled-agents.json.broken-'));
      expect(backups.length).toBeGreaterThan(0);
    });

    it('rejects primitive values (string) and backs them up', () => {
      setupConfigFile('default', '"a string"');
      const result = readEnabledAgents('default');
      expect(result).toEqual({});

      const backups = readdirSync(join(tmpHome, '.cortextos', 'default', 'config'))
        .filter(f => f.startsWith('enabled-agents.json.broken-'));
      expect(backups.length).toBeGreaterThan(0);
    });

    it('does not back up the file when JSON is valid', () => {
      setupConfigFile('default', '{}');
      readEnabledAgents('default');

      const backups = readdirSync(join(tmpHome, '.cortextos', 'default', 'config'))
        .filter(f => f.startsWith('enabled-agents.json.broken-'));
      expect(backups.length).toBe(0);
    });
  });
});

/**
 * Bus-only agents: backend workers with no Telegram channel.
 *
 * The daemon has always supported these — agent-manager rejects any BOT_TOKEN
 * that is not `<numeric_id>:<secret>`, leaves Telegram unstarted, and boots the
 * agent anyway. Only `cortextos enable`'s Telegram preflight hard-failed, so a
 * legitimate backend agent could not be registered at all.
 *
 * 2026-08-11: vectorbt-dev and backtest-runner sat unusable because of this.
 * Both are pure backend workers that never needed a bot.
 *
 * The contract these tests lock in: the sentinel is the ONLY way to declare
 * bus-only. A missing or empty BOT_TOKEN must NOT qualify, because that is
 * indistinguishable from a Telegram agent whose token was lost or stripped —
 * enabling that agent with a silently dead channel is the exact failure the
 * preflight exists to catch.
 */
describe('bus-only agents: isBusOnlyAgent', () => {
  it('recognises the exact sentinel', () => {
    expect(isBusOnlyAgent({ BOT_TOKEN: BUS_ONLY_TOKEN })).toBe(true);
  });

  it('tolerates surrounding whitespace from hand-edited .env files', () => {
    expect(isBusOnlyAgent({ BOT_TOKEN: `  ${BUS_ONLY_TOKEN}  ` })).toBe(true);
  });

  it('does not require CHAT_ID', () => {
    expect(isBusOnlyAgent({ BOT_TOKEN: BUS_ONLY_TOKEN, CHAT_ID: undefined })).toBe(true);
  });

  it('does NOT treat a missing BOT_TOKEN as bus-only', () => {
    expect(isBusOnlyAgent({})).toBe(false);
  });

  it('does NOT treat an empty BOT_TOKEN as bus-only', () => {
    expect(isBusOnlyAgent({ BOT_TOKEN: '' })).toBe(false);
    expect(isBusOnlyAgent({ BOT_TOKEN: '   ' })).toBe(false);
  });

  it('does NOT treat a real Telegram token as bus-only', () => {
    expect(isBusOnlyAgent({ BOT_TOKEN: '8604768367:AAFakeSecretValueHere' })).toBe(false);
  });

  it('does NOT treat a stripped-token sentinel as bus-only', () => {
    // The 2026-08-11 token-dedup pass replaced duplicated tokens with this
    // marker. Such an agent is broken, not bus-only, and must still fail the
    // preflight rather than silently registering with no working channel.
    expect(isBusOnlyAgent({ BOT_TOKEN: 'REMOVED_DUPLICATE_OF_notes_ma_braindump_bot' })).toBe(false);
    expect(isBusOnlyAgent({ BOT_TOKEN: 'NEEDS_NEW_BOT' })).toBe(false);
  });

  it('is case-sensitive — near-misses do not qualify', () => {
    expect(isBusOnlyAgent({ BOT_TOKEN: 'BUS-ONLY' })).toBe(false);
    expect(isBusOnlyAgent({ BOT_TOKEN: 'bus_only' })).toBe(false);
    expect(isBusOnlyAgent({ BOT_TOKEN: 'bus-only-agent' })).toBe(false);
  });
});
