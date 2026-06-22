import { NextResponse } from 'next/server';
import { orbPool } from '@/lib/orbfutures-db';

export const dynamic = 'force-dynamic';

/**
 * GET /api/nt8/trades
 *
 * Query params:
 *   date       YYYY-MM-DD  (default: today)
 *   account    account_name filter (optional)
 *   days       number of days back (overrides date, default: 1)
 *   open       "true" to return only open positions
 */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const openOnly = searchParams.get('open') === 'true';
  const account = searchParams.get('account');
  const days = parseInt(searchParams.get('days') ?? '1', 10);
  const dateParam = searchParams.get('date');

  try {
    const conditions: string[] = [];
    const params: (string | number | boolean)[] = [];
    let p = 1;

    if (openOnly) {
      conditions.push('t.exit_time IS NULL');
    } else {
      if (dateParam) {
        conditions.push(`t.entry_time >= $${p}::date AND t.entry_time < $${p}::date + interval '1 day'`);
        params.push(dateParam);
        p++;
      } else {
        conditions.push(`t.entry_time >= CURRENT_DATE - ($${p} - 1) * interval '1 day'`);
        params.push(days);
        p++;
      }
    }

    if (account) {
      conditions.push(`t.account_name = $${p}`);
      params.push(account);
      p++;
    }

    const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const tradesQuery = `
      SELECT
        t.id,
        t.account_name,
        t.instrument,
        t.strategy_name,
        t.direction,
        t.entry_time AT TIME ZONE 'America/Chicago' AS entry_ct,
        t.exit_time  AT TIME ZONE 'America/Chicago' AS exit_ct,
        t.entry_price,
        t.exit_price,
        t.qty,
        t.pnl_dollars,
        t.exit_signal,
        t.commission,
        t.tp_ticks,
        t.sl_ticks,
        t.orb_range_ticks,
        s.vix_regime,
        s.orb_high,
        s.orb_low,
        s.effective_direction,
        s.exit_mode,
        s.sod_balance
      FROM trades t
      LEFT JOIN mov_sessions s
             ON s.account_name = t.account_name
            AND s.session_date = t.entry_time::date
      ${whereClause}
      ORDER BY t.entry_time DESC
      LIMIT 500
    `;

    const summaryQuery = `
      SELECT
        t.account_name,
        t.instrument,
        COUNT(*) FILTER (WHERE t.exit_time IS NOT NULL)       AS completed,
        COUNT(*) FILTER (WHERE t.exit_time IS NULL)           AS open,
        SUM(t.pnl_dollars) FILTER (WHERE t.exit_time IS NOT NULL) AS total_pnl,
        COUNT(*) FILTER (WHERE t.pnl_dollars > 0)             AS winners,
        COUNT(*) FILTER (WHERE t.pnl_dollars <= 0 AND t.exit_time IS NOT NULL) AS losers
      FROM trades t
      ${whereClause}
      GROUP BY t.account_name, t.instrument
      ORDER BY total_pnl DESC NULLS LAST
    `;

    const [tradesResult, summaryResult] = await Promise.all([
      orbPool.query(tradesQuery, params),
      orbPool.query(summaryQuery, params),
    ]);

    return NextResponse.json({
      trades: tradesResult.rows,
      summary: summaryResult.rows,
      query: { days, date: dateParam, account, open_only: openOnly },
      count: tradesResult.rows.length,
    });
  } catch (err) {
    console.error('[api/nt8/trades] DB error:', err);
    return NextResponse.json({ error: 'Database query failed', detail: String(err) }, { status: 500 });
  }
}
