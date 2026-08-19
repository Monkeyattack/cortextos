import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

const mockFetch = vi.fn();
vi.stubGlobal('fetch', mockFetch);

const { checkUsageApi, loadAccounts } = await import('../../../src/bus/oauth.js');

// Captured live from GET https://api.anthropic.com/api/oauth/usage on 2026-08-14.
const REAL_RESPONSE = JSON.parse(
  readFileSync(new URL('../../fixtures/oauth-usage-response.json', import.meta.url), 'utf-8'),
);

const FOUR_HOURS_MS = 4 * 60 * 60 * 1000;

const STORE = {
  active: 'primary',
  accounts: {
    primary: {
      label: 'Primary Account',
      access_token: 'tok_primary_abc',
      refresh_token: 'rtok_primary_xyz',
      expires_at: Date.now() + FOUR_HOURS_MS,
      last_refreshed: '2026-08-14T00:00:00Z',
      five_hour_utilization: 0.3,
      seven_day_utilization: 0.2,
    },
  },
  rotation_log: [],
};

let tmpDir: string;

function writeStore() {
  const oauthDir = join(tmpDir, 'state', 'oauth');
  mkdirSync(oauthDir, { recursive: true });
  writeFileSync(join(oauthDir, 'accounts.json'), JSON.stringify(STORE, null, 2));
}

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), 'cortextos-oauth-fields-'));
  mockFetch.mockReset();
  writeStore();
});

afterEach(() => {
  try { rmSync(tmpDir, { recursive: true }); } catch { /* ignore */ }
});

function mockOnce(body: unknown) {
  mockFetch.mockResolvedValueOnce({ ok: true, json: async () => body });
}

// --- Regression pin: the two floats rotate-oauth thresholds on -------------
// These exact values were produced by the pre-change normalizer against this
// same captured response. If either shifts, quota rotation has been broken.

describe('utilization floats are unchanged by field surfacing', () => {
  it('parses the real captured response to the pinned floats', async () => {
    mockOnce(REAL_RESPONSE);
    const result = await checkUsageApi(tmpDir, { force: true });
    expect(result.five_hour_utilization).toBe(0);
    expect(result.seven_day_utilization).toBe(1);
    // eslint-disable-next-line no-console
    console.log(
      `PINNED FLOATS: five_hour_utilization=${result.five_hour_utilization} seven_day_utilization=${result.seven_day_utilization}`,
    );
  });

  it('still writes the floats through to accounts.json', async () => {
    mockOnce(REAL_RESPONSE);
    await checkUsageApi(tmpDir, { force: true });
    const store = loadAccounts(tmpDir)!;
    expect(store.accounts.primary.five_hour_utilization).toBe(0);
    expect(store.accounts.primary.seven_day_utilization).toBe(1);
  });

  it('preserves the nested / flat / camelCase fallback chain', async () => {
    mockOnce({ five_hour: { utilization: 0.42 }, seven_day: { utilization: 0.18 } });
    const nested = await checkUsageApi(tmpDir, { force: true });
    expect(nested.five_hour_utilization).toBeCloseTo(0.42);
    expect(nested.seven_day_utilization).toBeCloseTo(0.18);

    mockOnce({ five_hour_utilization: 0.42, seven_day_utilization: 0.18 });
    const flat = await checkUsageApi(tmpDir, { force: true });
    expect(flat.five_hour_utilization).toBeCloseTo(0.42);
    expect(flat.seven_day_utilization).toBeCloseTo(0.18);

    mockOnce({ fiveHourUtilization: 42, sevenDayUtilization: 18 });
    const camel = await checkUsageApi(tmpDir, { force: true });
    expect(camel.five_hour_utilization).toBeCloseTo(0.42);
    expect(camel.seven_day_utilization).toBeCloseTo(0.18);
  });
});

// --- New surfaced fields ---------------------------------------------------

describe('surfaced usage detail fields', () => {
  it('surfaces per-window resets_at from the real response', async () => {
    mockOnce(REAL_RESPONSE);
    const result = await checkUsageApi(tmpDir, { force: true });
    expect(result.five_hour_resets_at).toBeNull();
    expect(result.seven_day_resets_at).toBe('2026-08-17T22:00:00.031313+00:00');
  });

  it('surfaces extra_usage paid-credit cap and current use', async () => {
    mockOnce(REAL_RESPONSE);
    const result = await checkUsageApi(tmpDir, { force: true });
    expect(result.extra_usage?.is_enabled).toBe(true);
    expect(result.extra_usage?.monthly_limit).toBe(25000);
    expect(result.extra_usage?.used_credits).toBe(14667);
    expect(result.extra_usage?.utilization).toBeCloseTo(58.668);
    expect(result.extra_usage?.currency).toBe('USD');
    expect(result.extra_usage?.spend_limit_reached).toBe(false);
  });

  it('surfaces spend', async () => {
    mockOnce(REAL_RESPONSE);
    const result = await checkUsageApi(tmpDir, { force: true });
    expect(result.spend?.used_minor).toBe(14667);
    expect(result.spend?.limit_minor).toBe(25000);
    expect(result.spend?.currency).toBe('USD');
    expect(result.spend?.exponent).toBe(2);
    expect(result.spend?.percent).toBe(59);
    expect(result.spend?.severity).toBe('normal');
    expect(result.spend?.enabled).toBe(true);
  });

  it('surfaces per-window limits[] including model scope', async () => {
    mockOnce(REAL_RESPONSE);
    const result = await checkUsageApi(tmpDir, { force: true });
    expect(result.limits).toHaveLength(3);
    const weeklyAll = result.limits!.find((l) => l.kind === 'weekly_all');
    expect(weeklyAll).toMatchObject({
      group: 'weekly',
      percent: 100,
      severity: 'critical',
      resets_at: '2026-08-17T22:00:00.031313+00:00',
      is_active: true,
    });
    const scoped = result.limits!.find((l) => l.kind === 'weekly_scoped');
    expect(scoped?.scope_model).toBe('Fable');
  });

  it('persists the detail onto the account so list-oauth-accounts can read it', async () => {
    mockOnce(REAL_RESPONSE);
    await checkUsageApi(tmpDir, { force: true });
    const store = loadAccounts(tmpDir)!;
    expect(store.accounts.primary.usage_detail?.extra_usage?.used_credits).toBe(14667);
    expect(store.accounts.primary.usage_detail?.seven_day_resets_at).toBe(
      '2026-08-17T22:00:00.031313+00:00',
    );
  });
});

// --- Absent-field fixture --------------------------------------------------

describe('response missing the new fields', () => {
  it('still parses and still returns the two floats', async () => {
    // Deliberate fixture: only the two utilization windows, nothing else.
    mockOnce({ five_hour: { utilization: 0.42 }, seven_day: { utilization: 0.18 } });
    const result = await checkUsageApi(tmpDir, { force: true });

    expect(result.five_hour_utilization).toBeCloseTo(0.42);
    expect(result.seven_day_utilization).toBeCloseTo(0.18);
    expect(result.extra_usage).toBeUndefined();
    expect(result.spend).toBeUndefined();
    expect(result.limits).toBeUndefined();
    expect(result.five_hour_resets_at).toBeUndefined();
    expect(result.seven_day_resets_at).toBeUndefined();
  });

  it('handles a completely empty response body without throwing', async () => {
    mockOnce({});
    const result = await checkUsageApi(tmpDir, { force: true });
    expect(result.five_hour_utilization).toBe(0);
    expect(result.seven_day_utilization).toBe(0);
    expect(result.extra_usage).toBeUndefined();
  });
});
