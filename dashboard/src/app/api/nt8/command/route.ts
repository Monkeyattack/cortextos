import { NextResponse } from 'next/server';
import { readCommands, writeCommands, createCommand } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * POST /api/nt8/command
 *
 * Dashboard user sends a command to a relay node. Authenticated.
 * Command is queued; relay picks it up on next 2s poll.
 *
 * Body: {
 *   node_id: string,
 *   type: "enable_strategy" | "disable_strategy",
 *   strategy_name: string,
 *   account: string
 * }
 *
 * Response: { id: string } — command ID for status tracking
 */
export async function POST(request: Request) {
  let body: {
    node_id?: string;
    type?: string;
    strategy_name?: string;
    account?: string;
  };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { node_id, type, strategy_name, account } = body;

  if (!node_id || !type || !strategy_name || !account) {
    return NextResponse.json(
      { error: 'node_id, type, strategy_name, and account are required' },
      { status: 400 },
    );
  }

  if (type !== 'enable_strategy' && type !== 'disable_strategy') {
    return NextResponse.json(
      { error: 'type must be enable_strategy or disable_strategy' },
      { status: 400 },
    );
  }

  const cmd = createCommand(node_id, type, strategy_name, account);

  const queue = readCommands();
  queue.commands.push(cmd);

  try {
    writeCommands(queue);
  } catch (err) {
    return NextResponse.json({ error: `Command queue write failed: ${err}` }, { status: 500 });
  }

  return NextResponse.json({ id: cmd.id, expires_at: cmd.expires_at });
}
