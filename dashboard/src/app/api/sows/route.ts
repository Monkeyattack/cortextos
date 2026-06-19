import { NextRequest } from 'next/server';
import { db } from '@/lib/db';

export const dynamic = 'force-dynamic';

const VALID_STATUSES = ['draft', 'active', 'complete'];

function parseSOW(row: Record<string, unknown>) {
  return {
    ...row,
    in_scope: JSON.parse((row.in_scope as string) || '[]'),
    out_of_scope: JSON.parse((row.out_of_scope as string) || '[]'),
    deliverable_ids: JSON.parse((row.deliverable_ids as string) || '[]'),
  };
}

// GET /api/sows
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const org = searchParams.get('org');
  const status = searchParams.get('status');

  try {
    let query = 'SELECT * FROM sows WHERE 1=1';
    const params: string[] = [];
    if (org) { query += ' AND org = ?'; params.push(org); }
    if (status) { query += ' AND status = ?'; params.push(status); }
    query += ' ORDER BY created_at DESC';

    const rows = db.prepare(query).all(...params) as Record<string, unknown>[];
    return Response.json(rows.map(parseSOW));
  } catch (err) {
    console.error('[api/sows] GET error:', err);
    return Response.json({ error: 'Failed to fetch SOWs' }, { status: 500 });
  }
}

// POST /api/sows
export async function POST(request: NextRequest) {
  let body: Record<string, unknown>;
  try { body = await request.json(); } catch {
    return Response.json({ error: 'Invalid JSON' }, { status: 400 });
  }

  const { id, project, consumer, accepting_owner, objective, background, in_scope, out_of_scope, constraints, org } = body as Record<string, unknown>;

  if (!id || typeof id !== 'string') return Response.json({ error: 'id required' }, { status: 400 });
  if (!project || typeof project !== 'string') return Response.json({ error: 'project required' }, { status: 400 });
  if (!consumer || typeof consumer !== 'string') return Response.json({ error: 'consumer required' }, { status: 400 });
  if (!objective || typeof objective !== 'string') return Response.json({ error: 'objective required' }, { status: 400 });

  const now = new Date().toISOString();
  try {
    db.prepare(`
      INSERT INTO sows (id, project, consumer, accepting_owner, objective, background, in_scope, out_of_scope, constraints, org, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'draft', ?, ?)
    `).run(
      id,
      project,
      consumer,
      (accepting_owner as string) || 'pmo',
      objective,
      (background as string) || '',
      JSON.stringify(in_scope || []),
      JSON.stringify(out_of_scope || []),
      (constraints as string) || '',
      (org as string) || '',
      now,
      now,
    );

    const row = db.prepare('SELECT * FROM sows WHERE id = ?').get(id) as Record<string, unknown>;
    return Response.json(parseSOW(row), { status: 201 });
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException & { code?: string }).code === 'SQLITE_CONSTRAINT_PRIMARYKEY') {
      return Response.json({ error: 'SOW id already exists' }, { status: 409 });
    }
    console.error('[api/sows] POST error:', err);
    return Response.json({ error: 'Failed to create SOW' }, { status: 500 });
  }
}

// PATCH /api/sows — update status or add deliverable_id
export async function PATCH(request: NextRequest) {
  let body: Record<string, unknown>;
  try { body = await request.json(); } catch {
    return Response.json({ error: 'Invalid JSON' }, { status: 400 });
  }

  const { id, status, add_deliverable_id } = body as Record<string, unknown>;
  if (!id || typeof id !== 'string') return Response.json({ error: 'id required' }, { status: 400 });

  const sow = db.prepare('SELECT * FROM sows WHERE id = ?').get(id) as Record<string, unknown> | undefined;
  if (!sow) return Response.json({ error: 'SOW not found' }, { status: 404 });

  const now = new Date().toISOString();

  if (status) {
    if (!VALID_STATUSES.includes(status as string)) {
      return Response.json({ error: `Invalid status. Must be: ${VALID_STATUSES.join(', ')}` }, { status: 400 });
    }
    // complete requires all deliverables signed_off and zero integrity violations
    if (status === 'complete') {
      const delIds = JSON.parse((sow.deliverable_ids as string) || '[]') as string[];
      if (delIds.length === 0) {
        return Response.json({ error: 'Cannot complete SOW with no deliverables' }, { status: 422 });
      }
      const rows = db.prepare(
        `SELECT id, status FROM deliverables WHERE sow_id = ?`
      ).all(id) as { id: string; status: string }[];
      const violations = rows.filter(r => r.status !== 'signed_off');
      if (violations.length > 0) {
        return Response.json({
          error: 'Cannot complete SOW — deliverables not yet signed_off',
          pending: violations.map(v => v.id),
        }, { status: 422 });
      }
    }
    db.prepare('UPDATE sows SET status = ?, updated_at = ? WHERE id = ?').run(status, now, id);
  }

  if (add_deliverable_id && typeof add_deliverable_id === 'string') {
    const ids = JSON.parse((sow.deliverable_ids as string) || '[]') as string[];
    if (!ids.includes(add_deliverable_id)) {
      ids.push(add_deliverable_id);
      db.prepare('UPDATE sows SET deliverable_ids = ?, updated_at = ? WHERE id = ?').run(JSON.stringify(ids), now, id);
    }
  }

  const updated = db.prepare('SELECT * FROM sows WHERE id = ?').get(id) as Record<string, unknown>;
  return Response.json(parseSOW(updated));
}
