import { NextResponse } from 'next/server';
import fs from 'fs';
import path from 'path';

export const dynamic = 'force-dynamic';

/**
 * GET /api/flip-signal
 *
 * Returns the current go/no-go signal for the MarketOpenFlip NinjaScript strategy.
 * The pre-market check script writes a JSON file at 9:22 ET each weekday.
 * This endpoint reads that file and returns the signal.
 *
 * Response: { signal: "GO" | "SKIP", direction: "LONG" | "SHORT" | null, reason: string, checked_at: string }
 *
 * direction: if non-null, only the matching instance fires (LONG instance skips on "SHORT" and vice versa).
 * If no signal file exists for today, defaults to GO with no direction restriction.
 */
export async function GET() {
  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD UTC
  const signalPath = path.join('/tmp', `flip_signal_${today}.json`);

  try {
    if (!fs.existsSync(signalPath)) {
      // No file yet — default GO so strategy isn't blocked if script failed
      return NextResponse.json({
        signal: 'GO',
        direction: null,
        reason: 'No pre-market check file found — defaulting to GO',
        checked_at: null,
      });
    }

    const raw = fs.readFileSync(signalPath, 'utf-8');
    const data = JSON.parse(raw);
    if (!('direction' in data)) data.direction = null;
    return NextResponse.json(data);
  } catch (err) {
    return NextResponse.json({
      signal: 'GO',
      direction: null,
      reason: `Signal file read error — defaulting to GO: ${err}`,
      checked_at: null,
    });
  }
}
