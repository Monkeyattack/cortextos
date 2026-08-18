/**
 * Handoff → remember bridge.
 *
 * The remember plugin's SessionStart hook injects <agentDir>/.remember/remember.md
 * as "LAST HANDOFF" on every boot, but only the manual /remember skill ever writes
 * that file. cortextos handoffs write memory/handoffs/*.md, so the plugin slot
 * freezes and stale state is re-injected on every subsequent boot (observed on
 * writer_amazonians: Aug-4 state re-delivered 106 times).
 *
 * consumeHandoffBlock now mirrors the validated handoff doc into that slot. The
 * mirror is strictly best-effort: it must never break the handoff itself.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { join } from 'path';

const mockAgentPty = {
  spawn: vi.fn().mockResolvedValue(undefined),
  kill: vi.fn(),
  write: vi.fn(),
  getPid: vi.fn().mockReturnValue(12345),
  isAlive: vi.fn().mockReturnValue(true),
  onExit: vi.fn(),
  getOutputBuffer: vi.fn().mockReturnValue({ isBootstrapped: vi.fn().mockReturnValue(true) }),
  setTelegramHandle: vi.fn(),
};

vi.mock('../../../src/pty/agent-pty.js', () => ({
  AgentPTY: function AgentPTY() { return mockAgentPty; },
}));

vi.mock('../../../src/pty/codex-app-server-pty.js', () => ({
  CodexAppServerPTY: function CodexAppServerPTY() { return mockAgentPty; },
}));

vi.mock('../../../src/pty/hermes-pty.js', () => ({
  HermesPTY: function HermesPTY() { return mockAgentPty; },
  hermesDbExists: vi.fn().mockReturnValue(false),
}));

vi.mock('../../../src/pty/opencode-pty.js', () => ({
  OpencodePTY: function OpencodePTY() { return mockAgentPty; },
  opencodeSessionExists: vi.fn().mockReturnValue(false),
}));

vi.mock('../../../src/pty/inject.js', () => ({
  injectMessage: vi.fn(),
  MessageDedup: class { isDuplicate() { return false; } },
}));

const ensureDirMock = vi.fn();
vi.mock('../../../src/utils/atomic.js', () => ({
  ensureDir: (...args: unknown[]) => ensureDirMock(...args),
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

const fsMocks = {
  existsSync: vi.fn().mockReturnValue(false),
  readFileSync: vi.fn(),
  writeFileSync: vi.fn(),
  appendFileSync: vi.fn(),
  statSync: vi.fn(),
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

const { AgentProcess } = await import('../../../src/daemon/agent-process.js');

const AGENT_DIR = '/tmp/fw/orgs/acme/agents/handoff-agent';
const REMEMBER_PATH = join(AGENT_DIR, '.remember', 'remember.md');
const HANDOFF_DOC = '/tmp/fw/orgs/acme/agents/handoff-agent/memory/handoffs/handoff-2026-08-06.md';
const HANDOFF_BODY = '# Handoff\n- resumed mid-task\n';

const mockEnv = {
  instanceId: 'test',
  ctxRoot: '/tmp/test-ctx',
  frameworkRoot: '/tmp/fw',
  agentName: 'handoff-agent',
  agentDir: AGENT_DIR,
  org: 'acme',
  projectRoot: '/tmp/fw',
};

/** Marker present + doc present: the normal handoff path. */
function stubHandoffPresent(): void {
  fsMocks.existsSync.mockImplementation((path: unknown) =>
    typeof path === 'string' && (path.endsWith('.handoff-doc-path') || path === HANDOFF_DOC));
  fsMocks.readFileSync.mockImplementation((path: unknown) =>
    typeof path === 'string' && path === HANDOFF_DOC ? HANDOFF_BODY : HANDOFF_DOC);
}

function rememberWrites(): unknown[][] {
  return fsMocks.writeFileSync.mock.calls.filter(c => c[0] === REMEMBER_PATH);
}

async function bootPrompt(): Promise<string> {
  const ap = new AgentProcess('handoff-agent', mockEnv as any, {} as any);
  await ap.start();
  return String(mockAgentPty.spawn.mock.calls[0]?.[1] ?? '');
}

beforeEach(() => {
  mockAgentPty.spawn.mockClear();
  mockAgentPty.onExit.mockClear();
  ensureDirMock.mockReset();
  fsMocks.existsSync.mockReset().mockReturnValue(false);
  fsMocks.readFileSync.mockReset();
  fsMocks.writeFileSync.mockReset();
  fsMocks.appendFileSync.mockReset();
  fsMocks.statSync.mockReset();
});

describe('handoff → .remember/remember.md mirror', () => {
  it('mirrors the handoff doc into .remember/remember.md when the doc exists', async () => {
    stubHandoffPresent();

    const prompt = await bootPrompt();

    expect(prompt).toContain('CONTEXT HANDOFF');
    expect(ensureDirMock).toHaveBeenCalledWith(join(AGENT_DIR, '.remember'));
    expect(rememberWrites()).toEqual([[REMEMBER_PATH, HANDOFF_BODY, 'utf-8']]);
  });

  it('writes nothing when the handoff doc is missing', async () => {
    // Marker exists and points at a doc, but the doc itself is gone.
    fsMocks.existsSync.mockImplementation((path: unknown) =>
      typeof path === 'string' && path.endsWith('.handoff-doc-path'));
    fsMocks.readFileSync.mockReturnValue(HANDOFF_DOC);

    const prompt = await bootPrompt();

    expect(prompt).not.toContain('CONTEXT HANDOFF');
    expect(rememberWrites()).toEqual([]);
    expect(ensureDirMock).not.toHaveBeenCalledWith(join(AGENT_DIR, '.remember'));
  });

  it('still returns the handoff block when the mirror write fails', async () => {
    stubHandoffPresent();
    fsMocks.writeFileSync.mockImplementation((path: unknown) => {
      if (path === REMEMBER_PATH) throw new Error('EACCES: read-only file system');
    });

    const prompt = await bootPrompt();

    expect(prompt).toContain('CONTEXT HANDOFF');
    expect(prompt).toContain(HANDOFF_DOC);
    expect(rememberWrites()).toHaveLength(1);
  });
});
