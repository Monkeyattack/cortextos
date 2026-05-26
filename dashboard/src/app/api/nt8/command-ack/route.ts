import { NextResponse } from 'next/server';
import { readCommands, writeCommands } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * POST /api/nt8/command-ack
 *
 * ATI Relay Agent acknowledges command execution (unauthenticated — from VPS).
 *
 * Body: { request_id: string, success: boolean, error: string | null }
 */
export async function POST(request: Request) {
  let body: { request_id?: string; success?: boolean; error?: string | null };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { request_id, success, error } = body;

  if (!request_id) {
    return NextResponse.json({ error: 'request_id is required' }, { status: 400 });
  }

  const queue = readCommands();
  const cmd = queue.commands.find((c) => c.id === request_id);

  if (!cmd) {
    return NextResponse.json({ error: 'Command not found' }, { status: 404 });
  }

  cmd.acked = true;
  cmd.ack_success = success ?? false;
  cmd.ack_error = error ?? null;

  try {
    writeCommands(queue);
  } catch (err) {
    return NextResponse.json({ error: `State write failed: ${err}` }, { status: 500 });
  }

  return NextResponse.json({ ok: true });
}
