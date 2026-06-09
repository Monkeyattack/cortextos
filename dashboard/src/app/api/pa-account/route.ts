import { NextResponse } from 'next/server';
import fs from 'fs';
import path from 'path';

export const dynamic = 'force-dynamic';

const STATE_PATH = path.join('/tmp', 'pa_account.json');

function readState(): { updated_at: string | null; accounts: Record<string, unknown>[] } {
  try {
    if (!fs.existsSync(STATE_PATH)) return { updated_at: null, accounts: [] };
    return JSON.parse(fs.readFileSync(STATE_PATH, 'utf-8'));
  } catch {
    return { updated_at: null, accounts: [] };
  }
}

function computeStatus(
  balance: number | null,
  threshold: number | null,
): { status: string; status_reason: string } {
  if (balance === null || balance === 0) {
    return { status: 'INACTIVE', status_reason: 'No readable balance — account inactive or unreadable' };
  }
  if (threshold === null) {
    return { status: 'ACTIVE', status_reason: 'Balance present but no drawdown threshold configured' };
  }
  if (balance <= threshold) {
    return { status: 'HALTED', status_reason: 'Balance at or below trailing drawdown threshold — halt trading' };
  }
  if (balance <= threshold * 1.1) {
    return { status: 'AT_RISK', status_reason: 'Balance within 10% of trailing drawdown threshold' };
  }
  return { status: 'ACTIVE', status_reason: 'Within normal parameters' };
}

/**
 * GET /api/pa-account[?account_id=APEX-123]
 *
 * Returns Apex prop account metrics for NT8 MonkeyAttackMonitor.
 * Written by scripts/refresh-pa-account.sh on a schedule (devops cron).
 *
 * NT8 uses this to enforce:
 * - Trailing drawdown threshold (halt if balance approaches threshold)
 * - Daily loss limit (halt if daily_pnl approaches daily_drawdown_limit)
 * - Account status (ACTIVE / AT_RISK / HALTED)
 *
 * Fail-open: if no state file exists, returns status=ACTIVE with nulls.
 * NT8 should treat null limits as "no server gate" and rely on local config.
 *
 * Response:
 * {
 *   account_id: string | null,
 *   balance: number | null,
 *   peak_balance: number | null,
 *   trailing_drawdown_threshold: number | null,
 *   daily_drawdown_limit: number | null,
 *   current_daily_pnl: number | null,
 *   status: "ACTIVE" | "AT_RISK" | "HALTED",
 *   status_reason: string,
 *   updated_at: string | null,
 * }
 */
/**
 * POST /api/pa-account
 *
 * NT8 NinjaScript pushes live equity/balance for an account.
 * Server recomputes status from stored trailing_drawdown_threshold.
 * Upserts account into state file — creates entry if not present (fail-open thresholds).
 *
 * Body: { account_id: string, balance: number, equity?: number, daily_pnl?: number }
 */
export async function POST(request: Request) {
  let body: { account_id?: string; balance?: number; equity?: number; daily_pnl?: number };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { account_id, balance, equity, daily_pnl } = body;
  if (!account_id || typeof balance !== 'number') {
    return NextResponse.json({ error: 'account_id and balance are required' }, { status: 400 });
  }

  const data = readState();
  const updatedAt = new Date().toISOString();

  const idx = data.accounts.findIndex((a) => (a as { account_id: string }).account_id === account_id);
  const existing = idx >= 0 ? data.accounts[idx] : null;

  const threshold = (existing as { trailing_drawdown_threshold?: number | null } | null)
    ?.trailing_drawdown_threshold ?? null;
  const { status, status_reason } = computeStatus(balance, threshold);

  const updated = {
    ...(existing ?? {}),
    account_id,
    balance,
    equity: equity ?? null,
    current_daily_pnl: daily_pnl ?? (existing as { current_daily_pnl?: unknown } | null)?.current_daily_pnl ?? null,
    trailing_drawdown_threshold: threshold,
    daily_drawdown_limit: (existing as { daily_drawdown_limit?: unknown } | null)?.daily_drawdown_limit ?? null,
    peak_balance: (existing as { peak_balance?: unknown } | null)?.peak_balance ?? null,
    status,
    status_reason,
  };

  if (idx >= 0) {
    data.accounts[idx] = updated;
  } else {
    data.accounts.push(updated);
  }
  data.updated_at = updatedAt;

  try {
    const tmp = STATE_PATH + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
    fs.renameSync(tmp, STATE_PATH);
  } catch (err) {
    return NextResponse.json({ error: `State write failed: ${err}` }, { status: 500 });
  }

  return NextResponse.json({ ...updated, updated_at: updatedAt });
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const accountId = searchParams.get('account_id') ?? null;

  const failOpen = {
    account_id: accountId,
    balance: null,
    peak_balance: null,
    trailing_drawdown_threshold: null,
    daily_drawdown_limit: null,
    current_daily_pnl: null,
    status: 'ACTIVE',
    status_reason: 'No state file — defaulting to ACTIVE (fail-open)',
    updated_at: null,
  };

  try {
    const data = readState();

    if (data.accounts.length === 0 && !data.updated_at) {
      return NextResponse.json(failOpen);
    }

    if (accountId && data.accounts) {
      const account = data.accounts.find((a) => (a as { account_id: string }).account_id === accountId);
      if (!account) {
        return NextResponse.json({
          ...failOpen,
          status_reason: `Account ${accountId} not found in state file — defaulting to ACTIVE`,
          updated_at: data.updated_at,
        });
      }
      return NextResponse.json({ ...account, updated_at: data.updated_at });
    }

    if (data.accounts.length > 0) {
      return NextResponse.json({ ...data.accounts[0], updated_at: data.updated_at });
    }

    return NextResponse.json(failOpen);
  } catch (err) {
    return NextResponse.json({
      ...failOpen,
      status_reason: `State file read error — defaulting to ACTIVE: ${err}`,
    });
  }
}
