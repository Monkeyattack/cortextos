/**
 * Unit tests for the quota circuit-breaker in AgentProcess and the
 * refresh-floor constant in bus.ts.
 *
 * Mocking strategy mirrors agent-process-codex-app-server.test.ts:
 * - vi.mock all PTY constructors to return a controllable stub
 * - vi.mock fs, inject.js, atomic.js, env.js, reminders.js, paths.js
 * - vi.mock rate-limit-detect so we can toggle detectRateLimitInLog per test
 * - Capture the onExit callback and invoke it to drive handleExit()
 *
 * KEY DESIGN NOTE: start() resets consecutiveQuotaErrors=0 on successful spawn.
 * So to accumulate consecutive quota errors we fire handleExit() multiple times
 * on the SAME capturedOnExit (same PTY, same lifecycle generation) — no
 * intervening start() calls. The generation guard only bails when a NEW start()
 * increments the counter; firing the same callback twice is valid.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// ── Rate-limit mock: mutable so individual tests can flip the return value ──
const rateLimitDetect = { returnValue: false };

vi.mock('../../../src/utils/rate-limit-detect.js', () => ({
  detectRateLimitInLog: (_path: string) => rateLimitDetect.returnValue,
  RATE_LIMIT_RETRY_MS: 3_600_000,
}));

// ── PTY stubs ────────────────────────────────────────────────────────────────
let capturedOnExit: ((exitCode: number, signal?: number) => void) | null = null;

const mockPty = {
  spawn: vi.fn().mockResolvedValue(undefined),
  kill: vi.fn(),
  write: vi.fn(),
  getPid: vi.fn().mockReturnValue(12345),
  isAlive: vi.fn().mockReturnValue(true),
  onExit: vi.fn().mockImplementation((cb: (exitCode: number, signal?: number) => void) => {
    capturedOnExit = cb;
  }),
  getOutputBuffer: vi.fn().mockReturnValue({ isBootstrapped: vi.fn().mockReturnValue(true) }),
};

vi.mock('../../../src/pty/agent-pty.js', () => ({
  AgentPTY: function AgentPTY() { return mockPty; },
}));

vi.mock('../../../src/pty/codex-app-server-pty.js', () => ({
  CodexAppServerPTY: function CodexAppServerPTY() { return mockPty; },
}));

vi.mock('../../../src/pty/hermes-pty.js', () => ({
  HermesPTY: function HermesPTY() { return mockPty; },
  hermesDbExists: vi.fn().mockReturnValue(false),
}));

vi.mock('../../../src/pty/opencode-pty.js', () => ({
  OpencodePTY: function OpencodePTY() { return mockPty; },
  opencodeSessionExists: vi.fn().mockReturnValue(false),
}));

// ── Inject / dedup stubs ─────────────────────────────────────────────────────
vi.mock('../../../src/pty/inject.js', () => ({
  injectMessage: vi.fn(),
  MessageDedup: class { isDuplicate() { return false; } },
}));

// ── FS stubs (intercepted for daemon code; real fs available via importActual) ─
const fsMocks = {
  existsSync: vi.fn().mockReturnValue(false),
  readFileSync: vi.fn().mockReturnValue(''),
  writeFileSync: vi.fn(),
  appendFileSync: vi.fn(),
  statSync: vi.fn().mockReturnValue({ size: 0 }),
};

vi.mock('fs', async () => {
  const actual = await vi.importActual<typeof import('fs')>('fs');
  return {
    ...actual,
    mkdirSync: vi.fn(),
    unlinkSync: vi.fn(),
    get existsSync() { return fsMocks.existsSync; },
    get readFileSync() { return fsMocks.readFileSync; },
    get writeFileSync() { return fsMocks.writeFileSync; },
    get appendFileSync() { return fsMocks.appendFileSync; },
    get statSync() { return fsMocks.statSync; },
  };
});

// ── Misc stubs ───────────────────────────────────────────────────────────────
vi.mock('../../../src/utils/atomic.js', () => ({
  ensureDir: vi.fn(),
  atomicWriteSync: vi.fn(),
}));

vi.mock('../../../src/utils/env.js', () => ({
  writeCortextosEnv: vi.fn(),
  resolveEnv: vi.fn().mockReturnValue({ instanceId: 'test', ctxRoot: '/tmp/test' }),
}));

vi.mock('../../../src/bus/reminders.js', () => ({
  getOverdueReminders: vi.fn().mockReturnValue([]),
}));

vi.mock('../../../src/utils/paths.js', () => ({
  resolvePaths: vi.fn().mockReturnValue({}),
}));

// ── Import the class AFTER all mocks are registered ─────────────────────────
const { AgentProcess } = await import('../../../src/daemon/agent-process.js');

// ── Shared test env ──────────────────────────────────────────────────────────
const mockEnv = {
  instanceId: 'test',
  ctxRoot: '/tmp/test-ctx',
  frameworkRoot: '/tmp/fw',
  agentName: 'test-agent',
  agentDir: '/tmp/fw/orgs/acme/agents/test-agent',
  org: 'acme',
  projectRoot: '/tmp/fw',
};

beforeEach(() => {
  capturedOnExit = null;
  rateLimitDetect.returnValue = false;

  mockPty.spawn.mockClear();
  mockPty.kill.mockClear();
  mockPty.write.mockClear();
  mockPty.getPid.mockReset().mockReturnValue(12345);
  mockPty.isAlive.mockReset().mockReturnValue(true);
  mockPty.onExit.mockClear().mockImplementation((cb: (exitCode: number, signal?: number) => void) => {
    capturedOnExit = cb;
  });
  mockPty.getOutputBuffer.mockReset().mockReturnValue({ isBootstrapped: vi.fn().mockReturnValue(true) });

  fsMocks.existsSync.mockReset().mockReturnValue(false);
  fsMocks.readFileSync.mockReset().mockReturnValue('');
  fsMocks.writeFileSync.mockReset();
  fsMocks.appendFileSync.mockReset();
  fsMocks.statSync.mockReset().mockReturnValue({ size: 0 });

  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

// ── Helper: start an agent and wait for 'running' ────────────────────────────
async function startAgent(config: Record<string, unknown> = {}) {
  const ap = new AgentProcess('test-agent', mockEnv, config);
  await ap.start();
  return ap;
}

// ── Helper: fire handleExit() via the captured PTY onExit callback ───────────
//    Calling this multiple times without an intervening start() accumulates the
//    consecutiveQuotaErrors counter (same generation, no reset).
function fireExit(code = 1) {
  if (!capturedOnExit) throw new Error('onExit callback was not captured — did start() run?');
  capturedOnExit(code);
}

// ── Helper: fire N consecutive quota exits and capture the setTimeout delays ─
async function fireQuotaExits(ap: InstanceType<typeof AgentProcess>, count: number): Promise<number[]> {
  rateLimitDetect.returnValue = true;
  const delays: number[] = [];
  const origSetTimeout = globalThis.setTimeout;

  vi.spyOn(globalThis, 'setTimeout').mockImplementation((fn: any, delay?: number, ...args: any[]) => {
    if (typeof delay === 'number' && delay > 1000) delays.push(delay);
    // Don't actually schedule — this is fake-timers territory and we don't want
    // the backoff restart to fire and reset the counter mid-test.
    return origSetTimeout(() => {}, 0);
  });

  for (let i = 0; i < count; i++) {
    fireExit(1);
  }

  return delays;
}

// ────────────────────────────────────────────────────────────────────────────
describe('quota circuit-breaker — jitter bounds', () => {
  it('quota-backoff jitter is within ±25% of base for error level 1 (60 s base)', async () => {
    const ap = await startAgent();
    const delays = await fireQuotaExits(ap, 1);

    expect(ap.getStatus().status).toBe('crashed');
    expect(delays.length).toBeGreaterThan(0);
    const d = delays[0];
    // base = 60_000; allowed range [45_000, 75_000]
    expect(d).toBeGreaterThanOrEqual(45_000);
    expect(d).toBeLessThanOrEqual(75_000);
  });

  it('quota-backoff jitter is within ±25% of base for error level 2 (120 s base)', async () => {
    const ap = await startAgent();
    // Fire 2 exits consecutively — no intervening start(), so counter accumulates to 2
    const delays = await fireQuotaExits(ap, 2);

    // Both exits set status='crashed'; last one is level-2 with 120s base
    expect(ap.getStatus().status).toBe('crashed');
    expect(delays.length).toBeGreaterThanOrEqual(2);
    const d = delays[1]; // second exit uses level-2 base
    // base = 120_000; allowed range [90_000, 150_000]
    expect(d).toBeGreaterThanOrEqual(90_000);
    expect(d).toBeLessThanOrEqual(150_000);
  });

  it('quota-backoff jitter is within ±25% of base for error level 3 (240 s base)', async () => {
    const ap = await startAgent();
    // Fire 3 exits consecutively — counter accumulates to 3
    const delays = await fireQuotaExits(ap, 3);

    expect(ap.getStatus().status).toBe('crashed');
    expect(delays.length).toBeGreaterThanOrEqual(3);
    const d = delays[2]; // third exit uses level-3 base
    // base = 240_000; allowed range [180_000, 300_000]
    expect(d).toBeGreaterThanOrEqual(180_000);
    expect(d).toBeLessThanOrEqual(300_000);
  });
});

// ────────────────────────────────────────────────────────────────────────────
describe('quota circuit-breaker — suspension at 4th error', () => {
  it('sets status to quota-suspended (not crashed) on 4th consecutive quota error', async () => {
    const ap = await startAgent();
    // Fire 4 exits — exits 1-3 should be 'crashed'; exit 4 opens the circuit
    await fireQuotaExits(ap, 4);

    expect(ap.getStatus().status).toBe('quota-suspended');
  });

  it('does NOT call setTimeout on the 4th exit (circuit open — no retry scheduled)', async () => {
    const ap = await startAgent();
    const delays: number[] = [];
    const origSetTimeout = globalThis.setTimeout;
    vi.spyOn(globalThis, 'setTimeout').mockImplementation((fn: any, delay?: number, ...args: any[]) => {
      if (typeof delay === 'number' && delay > 1000) delays.push(delay);
      return origSetTimeout(() => {}, 0);
    });

    rateLimitDetect.returnValue = true;
    // Fire 3 exits to accumulate counter, then a 4th for suspension
    for (let i = 0; i < 4; i++) {
      fireExit(1);
    }

    // Delays collected for exits 1-3 (backoffs); exit 4 must NOT add a delay
    expect(delays.length).toBe(3);
    expect(ap.getStatus().status).toBe('quota-suspended');
  });
});

// ────────────────────────────────────────────────────────────────────────────
describe('quota circuit-breaker — counter reset on successful start', () => {
  it('resets consecutiveQuotaErrors to 0 after a successful start()', async () => {
    const ap = await startAgent();

    // Track ALL setTimeout delays across the whole test in one spy, installed once.
    const allDelays: number[] = [];
    const origSetTimeout = globalThis.setTimeout;
    vi.spyOn(globalThis, 'setTimeout').mockImplementation((fn: any, delay?: number, ...args: any[]) => {
      if (typeof delay === 'number' && delay > 1000) allDelays.push(delay);
      // Do NOT actually schedule — fake timers + preventing backoff restart
      return origSetTimeout(() => {}, 0);
    });

    // Cause two consecutive quota exits (counter → 2)
    rateLimitDetect.returnValue = true;
    fireExit(1); // exit #1: level-1 delay captured
    fireExit(1); // exit #2: level-2 delay captured

    // Simulate quota clearing — do a fresh start() which resets the counter to 0
    rateLimitDetect.returnValue = false;
    mockPty.onExit.mockClear().mockImplementation((cb: (exitCode: number, signal?: number) => void) => {
      capturedOnExit = cb;
    });
    await ap.start();

    // Should be 'running' after successful start
    expect(ap.getStatus().status).toBe('running');

    // Snapshot delays count before the post-reset exit
    const delaysBeforeReset = allDelays.length;

    // Next quota exit should use level-1 base (60s base) — counter was reset to 0
    rateLimitDetect.returnValue = true;
    fireExit(1);

    // Should still be 'crashed' — only 1st quota error after reset (not suspended)
    expect(ap.getStatus().status).toBe('crashed');

    // A new delay should have been recorded after the reset
    expect(allDelays.length).toBeGreaterThan(delaysBeforeReset);
    const postResetDelay = allDelays[delaysBeforeReset];
    // Level-1 base = 60_000; ±25% → [45_000, 75_000]
    expect(postResetDelay).toBeGreaterThanOrEqual(45_000);
    expect(postResetDelay).toBeLessThanOrEqual(75_000);
  });
});

// ────────────────────────────────────────────────────────────────────────────
describe('refresh-floor: STATUS_LINE.refreshInterval', () => {
  it('STATUS_LINE refreshInterval in bus.ts patch-settings is 60', async () => {
    // Use vi.importActual to bypass the fs mock and read bus.ts source directly
    const { readFileSync } = await vi.importActual<typeof import('fs')>('fs');
    const { join } = await vi.importActual<typeof import('path')>('path');
    const busPath = join(new URL('.', import.meta.url).pathname, '../../../src/cli/bus.ts');
    const busSource = (readFileSync as (p: string, enc: string) => string)(busPath, 'utf-8');

    const match = busSource.match(/const STATUS_LINE\s*=\s*\{[^}]*refreshInterval:\s*(\d+)/s);
    expect(match).not.toBeNull();
    expect(Number(match![1])).toBe(60);
  });
});
