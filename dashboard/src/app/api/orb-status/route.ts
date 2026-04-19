import { NextResponse } from 'next/server';
import fs from 'fs';
import path from 'path';

export const dynamic = 'force-dynamic';

/**
 * GET /api/orb-status[?instrument=MCL]
 *
 * Returns the current ACTIVE/PAUSED status for ORB instruments.
 * Written nightly by forward_test.py after evaluating OVX + rolling WR.
 *
 * Resume conditions (MCL): OVX < 40 AND 10-trade WR > 40%
 *
 * Response: { instrument: string, status: "ACTIVE" | "PAUSED", reason: string,
 *             ovx: number | null, wr_recent: number | null, updated_at: string }
 *
 * Fail-open: if no status file exists, defaults to ACTIVE (don't block on stale data).
 */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const instrument = (searchParams.get('instrument') || 'MCL').toUpperCase();

  const statusPath = path.join('/tmp', 'orb_status.json');

  try {
    if (!fs.existsSync(statusPath)) {
      return NextResponse.json({
        instrument,
        status: 'ACTIVE',
        reason: 'No status file found — defaulting to ACTIVE',
        ovx: null,
        wr_recent: null,
        updated_at: null,
      });
    }

    const raw = fs.readFileSync(statusPath, 'utf-8');
    const data = JSON.parse(raw);

    if (!(instrument in data)) {
      return NextResponse.json({
        instrument,
        status: 'ACTIVE',
        reason: `Instrument ${instrument} not in status file — defaulting to ACTIVE`,
        ovx: null,
        wr_recent: null,
        updated_at: data.updated_at ?? null,
      });
    }

    return NextResponse.json({ instrument, ...data[instrument], updated_at: data.updated_at });
  } catch (err) {
    return NextResponse.json({
      instrument,
      status: 'ACTIVE',
      reason: `Status file read error — defaulting to ACTIVE: ${err}`,
      ovx: null,
      wr_recent: null,
      updated_at: null,
    });
  }
}
