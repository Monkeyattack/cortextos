/**
 * Unit tests for the Guard 2 runtime clamp in AgentManager.startAgent().
 *
 * These tests live in a separate file from quota-circuit-breaker.test.ts because
 * that file mocks AgentProcess at the PTY layer (to test circuit-breaker logic),
 * while this file stubs AgentProcess entirely so AgentManager can be imported
 * without native bindings. The two mock shapes are incompatible within a single
 * module scope.
 *
 * Tests verify: when startAgent() finds a settings.json with
 * statusLine.refreshInterval < 30, it clamps to 30, writes the file back, and
 * emits a console.warn.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

// ── AgentProcess stub: just needs to start() without crashing ────────────────
vi.mock('../../../src/daemon/agent-process.js', () => ({
  AgentProcess: class {
    name: string;
    _onStatusChange: ((s: any) => void) | null = null;
    constructor(name: string) { this.name = name; }
    async start() { /* no-op */ }
    async stop() { /* no-op */ }
    getStatus() { return { name: this.name, status: 'stopped' as const }; }
    onStatusChanged(cb: (s: any) => void) { this._onStatusChange = cb; }
    setTelegramHandle() { /* no-op */ }
  },
}));

// ── FastChecker stub ─────────────────────────────────────────────────────────
vi.mock('../../../src/daemon/fast-checker.js', () => ({
  FastChecker: class {
    start() { return Promise.resolve(); }
    stop() { /* no-op */ }
    wake() { /* no-op */ }
  },
}));

// ── CronScheduler stub ───────────────────────────────────────────────────────
vi.mock('../../../src/daemon/cron-scheduler.js', () => ({
  CronScheduler: class {
    start() { /* no-op */ }
    stop() { /* no-op */ }
    getNextFireTimes() { return []; }
  },
}));

// ── cron-migration stub ──────────────────────────────────────────────────────
vi.mock('../../../src/daemon/cron-migration.js', () => ({
  migrateCronsForAgent: vi.fn(),
}));

// ── WorkerProcess stub ───────────────────────────────────────────────────────
vi.mock('../../../src/daemon/worker-process.js', () => ({
  WorkerProcess: class {
    start() { /* no-op */ }
    stop() { /* no-op */ }
  },
}));

// ── Telegram stubs ───────────────────────────────────────────────────────────
vi.mock('../../../src/telegram/api.js', () => ({
  TelegramAPI: class {
    constructor() { /* no-op */ }
    sendMessage() { return Promise.resolve(); }
  },
}));

vi.mock('../../../src/telegram/poller.js', () => ({
  TelegramPoller: class {
    start() { return Promise.resolve(); }
    stop() { /* no-op */ }
  },
}));

// ── Logging / utility stubs ──────────────────────────────────────────────────
vi.mock('../../../src/telegram/logging.js', () => ({
  recordInboundTelegram: vi.fn(),
  cacheLastSent: vi.fn(),
  logOutboundMessage: vi.fn(),
  buildRecentHistory: vi.fn().mockReturnValue([]),
}));

vi.mock('../../../src/bus/metrics.js', () => ({
  collectTelegramCommands: vi.fn().mockReturnValue([]),
  registerTelegramCommands: vi.fn().mockResolvedValue({ status: 'empty' }),
}));

vi.mock('../../../src/utils/validate.js', () => ({
  stripControlChars: (s: string) => s,
}));

vi.mock('../../../src/telegram/media.js', () => ({
  processMediaMessage: vi.fn().mockResolvedValue(null),
}));

vi.mock('../../../src/utils/paths.js', () => ({
  resolvePaths: vi.fn().mockReturnValue({}),
}));

vi.mock('../../../src/utils/env.js', () => ({
  resolveEnv: vi.fn().mockReturnValue({ instanceId: 'test', ctxRoot: '/tmp/test' }),
  writeCortextosEnv: vi.fn(),
}));

// ── Import AgentManager after all mocks ─────────────────────────────────────
const { AgentManager } = await import('../../../src/daemon/agent-manager.js');

// ── Test fixtures ────────────────────────────────────────────────────────────
let testDir: string;
let ctxRoot: string;
let frameworkRoot: string;
let agentDir: string;

beforeEach(() => {
  testDir = mkdtempSync(join(tmpdir(), 'cortextos-rf-'));
  ctxRoot = join(testDir, 'instance');
  frameworkRoot = join(testDir, 'framework');
  agentDir = join(frameworkRoot, 'orgs', 'acme', 'agents', 'alice');

  // Minimal directory structure
  mkdirSync(join(ctxRoot, 'config'), { recursive: true });
  mkdirSync(join(ctxRoot, 'state', 'alice'), { recursive: true });
  mkdirSync(join(ctxRoot, 'logs', 'alice'), { recursive: true });
  mkdirSync(join(agentDir, '.claude'), { recursive: true });

  // Minimal agent config so startAgent() doesn't bail early
  writeFileSync(join(agentDir, 'config.json'), JSON.stringify({ model: 'claude-haiku-4-5' }));
});

afterEach(() => {
  rmSync(testDir, { recursive: true, force: true });
  vi.restoreAllMocks();
});

// ────────────────────────────────────────────────────────────────────────────
describe('refresh-floor runtime clamp in AgentManager.startAgent()', () => {
  it('clamps statusLine.refreshInterval from 5 to 30 and emits console.warn', async () => {
    // Write a settings.json with a below-floor refreshInterval
    const settingsPath = join(agentDir, '.claude', 'settings.json');
    const original = {
      statusLine: {
        type: 'command',
        command: 'cortextos bus hook-context-status',
        refreshInterval: 5,
        timeout: 2,
      },
    };
    writeFileSync(settingsPath, JSON.stringify(original, null, 2));

    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const am = new AgentManager('test-instance', ctxRoot, frameworkRoot, 'acme');
    await am.startAgent('alice', agentDir, {});

    // File should have been rewritten with refreshInterval=30
    const written = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    expect(written.statusLine.refreshInterval).toBe(30);

    // Other fields on statusLine must be preserved (surgical clamp, not full replace)
    expect(written.statusLine.type).toBe('command');
    expect(written.statusLine.command).toBe('cortextos bus hook-context-status');

    // console.warn must have been called with the right message
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('statusLine.refreshInterval clamped 5s → 30s'),
    );
  });

  it('leaves settings.json untouched when refreshInterval is already 30', async () => {
    const settingsPath = join(agentDir, '.claude', 'settings.json');
    const original = { statusLine: { refreshInterval: 30 } };
    writeFileSync(settingsPath, JSON.stringify(original));

    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const am = new AgentManager('test-instance', ctxRoot, frameworkRoot, 'acme');
    await am.startAgent('alice', agentDir, {});

    const written = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    expect(written.statusLine.refreshInterval).toBe(30);
    expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining('clamped'));
  });

  it('leaves settings.json untouched when refreshInterval is above 30', async () => {
    const settingsPath = join(agentDir, '.claude', 'settings.json');
    const original = { statusLine: { refreshInterval: 120 } };
    writeFileSync(settingsPath, JSON.stringify(original));

    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const am = new AgentManager('test-instance', ctxRoot, frameworkRoot, 'acme');
    await am.startAgent('alice', agentDir, {});

    const written = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    expect(written.statusLine.refreshInterval).toBe(120);
    expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining('clamped'));
  });

  it('skips silently when settings.json does not exist', async () => {
    // No settings.json written — should not throw
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const am = new AgentManager('test-instance', ctxRoot, frameworkRoot, 'acme');
    await expect(am.startAgent('alice', agentDir, {})).resolves.not.toThrow();
    expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining('clamped'));
  });
});
