import { NextResponse } from 'next/server';
import fs from 'fs';
import path from 'path';

export const dynamic = 'force-dynamic';

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
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const accountId = searchParams.get('account_id') ?? null;

  const statePath = path.join('/tmp', 'pa_account.json');

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
    if (!fs.existsSync(statePath)) {
      return NextResponse.json(failOpen);
    }

    const raw = fs.readFileSync(statePath, 'utf-8');
    const data = JSON.parse(raw);

    // If account_id filter provided, return matching account or fail-open
    if (accountId && data.accounts) {
      const account = data.accounts.find((a: { account_id: string }) => a.account_id === accountId);
      if (!account) {
        return NextResponse.json({
          ...failOpen,
          status_reason: `Account ${accountId} not found in state file — defaulting to ACTIVE`,
          updated_at: data.updated_at ?? null,
        });
      }
      return NextResponse.json({ ...account, updated_at: data.updated_at });
    }

    // No filter — return first account or top-level data
    if (data.accounts && data.accounts.length > 0) {
      return NextResponse.json({ ...data.accounts[0], updated_at: data.updated_at });
    }

    return NextResponse.json({ ...data });
  } catch (err) {
    return NextResponse.json({
      ...failOpen,
      status_reason: `State file read error — defaulting to ACTIVE: ${err}`,
    });
  }
}
