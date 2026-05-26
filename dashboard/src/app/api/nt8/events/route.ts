import { NextResponse } from 'next/server';
import { appendEvent, readEvents } from '@/lib/nt8-state';
import type { Nt8Event } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * POST /api/nt8/events
 *
 * NT8 Watchdog AddOn posts audit events (unauthenticated — from VPS, no auth header possible).
 * Events are appended to /tmp/nt8_events.json ring buffer (max 200 entries).
 *
 * Body: {
 *   type: "auto_restore" | "restore_failed" | "error",
 *   node_id: string,
 *   account?: string,
 *   strategies_restored?: string[],
 *   message?: string,
 *   timestamp: string
 * }
 *
 * GET /api/nt8/events[?limit=50]
 *
 * Returns recent audit events. Authenticated (checked at middleware level).
 */
export async function POST(request: Request) {
  let body: Partial<Nt8Event>;

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  if (!body.type || !body.node_id) {
    return NextResponse.json({ error: 'type and node_id are required' }, { status: 400 });
  }

  const event: Nt8Event = {
    type: body.type,
    node_id: body.node_id,
    account: body.account,
    strategies_restored: body.strategies_restored,
    message: body.message,
    timestamp: body.timestamp ?? new Date().toISOString(),
  };

  try {
    appendEvent(event);
  } catch (err) {
    return NextResponse.json({ error: `Event write failed: ${err}` }, { status: 500 });
  }

  return NextResponse.json({ ok: true });
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const limit = Math.min(parseInt(searchParams.get('limit') ?? '50', 10), 200);

  const log = readEvents();
  const events = log.events.slice(-limit).reverse();

  return NextResponse.json({ events });
}
