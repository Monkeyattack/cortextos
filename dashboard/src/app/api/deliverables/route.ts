import { NextRequest } from 'next/server';
import { db } from '@/lib/db';

export const dynamic = 'force-dynamic';

const VALID_STATUSES = ['not_started', 'in_progress', 'needs_qa', 'qa_failed', 'qa_passed', 'signed_off'];
const VALID_CRITERION_RESULTS = ['pass', 'fail', 'pending'];
const VALID_CRITERION_TYPES = ['command', 'artifact-check', 'human-judgment'];

interface Criterion {
  id: string;
  statement: string;
  verify: { type: string; check: string; expected: string };
  result: string;
  verified_by: string | null;
}

interface DeliverableRow {
  id: string;
  sow_id: string;
  title: string;
  owner_agent: string;
  success_criteria: string;
  status: string;
  signed_off_by: string | null;
  signed_off_at: string | null;
  attempts: number;
  last_run: string | null;
  org: string;
  created_at: string;
  updated_at: string;
}

function parseDeliverable(row: DeliverableRow) {
  return {
    ...row,
    success_criteria: JSON.parse(row.success_criteria || '[]') as Criterion[],
  };
}

function checkIntegrity(criteria: Criterion[], owner_agent: string): string[] {
  const violations: string[] = [];
  for (const c of criteria) {
    if (c.result !== 'pending' && c.verified_by === owner_agent) {
      violations.push(`Criterion ${c.id}: verified_by (${c.verified_by}) must differ from owner_agent (prover≠verifier)`);
    }
    if (c.result !== 'pending' && !c.verified_by) {
      violations.push(`Criterion ${c.id}: verified_by must be set when result is ${c.result}`);
    }
  }
  return violations;
}

// GET /api/deliverables
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const sow_id = searchParams.get('sow_id');
  const org = searchParams.get('org');
  const status = searchParams.get('status');

  try {
    let query = 'SELECT * FROM deliverables WHERE 1=1';
    const params: string[] = [];
    if (sow_id) { query += ' AND sow_id = ?'; params.push(sow_id); }
    if (org) { query += ' AND org = ?'; params.push(org); }
    const stalled = searchParams.get('stalled');
    const thresholdHours = parseInt(searchParams.get('threshold_hours') || '24', 10);
    if (stalled === 'true') {
      query += " AND status IN ('in_progress', 'needs_qa', 'qa_failed') AND updated_at < datetime('now', '-' || ? || ' hours')";
      params.push(String(thresholdHours));
      // skip status filter since stalled already constrains it
    } else if (status) {
      query += ' AND status = ?';
      params.push(status);
    }
    query += ' ORDER BY created_at ASC';

    const rows = db.prepare(query).all(...params) as DeliverableRow[];
    return Response.json(rows.map(parseDeliverable));
  } catch (err) {
    console.error('[api/deliverables] GET error:', err);
    return Response.json({ error: 'Failed to fetch deliverables' }, { status: 500 });
  }
}

// POST /api/deliverables — create a new deliverable
export async function POST(request: NextRequest) {
  let body: Record<string, unknown>;
  try { body = await request.json(); } catch {
    return Response.json({ error: 'Invalid JSON' }, { status: 400 });
  }

  const { id, sow_id, title, owner_agent, success_criteria, org } = body as Record<string, unknown>;

  if (!id || typeof id !== 'string') return Response.json({ error: 'id required' }, { status: 400 });
  if (!sow_id || typeof sow_id !== 'string') return Response.json({ error: 'sow_id required' }, { status: 400 });
  if (!title || typeof title !== 'string') return Response.json({ error: 'title required' }, { status: 400 });
  if (!owner_agent || typeof owner_agent !== 'string') return Response.json({ error: 'owner_agent required' }, { status: 400 });

  const criteria = (success_criteria as Criterion[]) || [];
  // Vacuous-QA guard: reject empty criteria
  if (!Array.isArray(criteria) || criteria.length === 0) {
    return Response.json({ error: 'success_criteria must have at least one criterion (empty = invalid)' }, { status: 400 });
  }
  // Validate criterion structure
  for (const c of criteria) {
    if (!c.id || !c.statement) return Response.json({ error: `Criterion missing id or statement` }, { status: 400 });
    if (!c.verify?.type || !VALID_CRITERION_TYPES.includes(c.verify.type)) {
      return Response.json({ error: `Criterion ${c.id}: verify.type must be one of ${VALID_CRITERION_TYPES.join(', ')}` }, { status: 400 });
    }
    if (!c.verify?.check || !c.verify?.expected) {
      return Response.json({ error: `Criterion ${c.id}: verify.check and verify.expected required` }, { status: 400 });
    }
  }

  // Verify SOW exists
  const sow = db.prepare('SELECT id, accepting_owner FROM sows WHERE id = ?').get(sow_id) as { id: string; accepting_owner: string } | undefined;
  if (!sow) return Response.json({ error: `SOW ${sow_id} not found` }, { status: 404 });

  // Seed criteria with defaults
  const seededCriteria: Criterion[] = criteria.map(c => ({
    ...c,
    result: 'pending',
    verified_by: null,
  }));

  const now = new Date().toISOString();
  try {
    db.prepare(`
      INSERT INTO deliverables (id, sow_id, title, owner_agent, success_criteria, status, org, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 'not_started', ?, ?, ?)
    `).run(id, sow_id, title, owner_agent, JSON.stringify(seededCriteria), (org as string) || '', now, now);

    // Auto-register in SOW's deliverable_ids
    const existingIds = JSON.parse(
      (db.prepare('SELECT deliverable_ids FROM sows WHERE id = ?').get(sow_id) as { deliverable_ids: string }).deliverable_ids || '[]'
    ) as string[];
    if (!existingIds.includes(id)) {
      existingIds.push(id);
      db.prepare('UPDATE sows SET deliverable_ids = ?, updated_at = ? WHERE id = ?')
        .run(JSON.stringify(existingIds), now, sow_id);
    }

    const row = db.prepare('SELECT * FROM deliverables WHERE id = ?').get(id) as DeliverableRow;
    return Response.json(parseDeliverable(row), { status: 201 });
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException & { code?: string }).code === 'SQLITE_CONSTRAINT_PRIMARYKEY') {
      return Response.json({ error: 'Deliverable id already exists' }, { status: 409 });
    }
    console.error('[api/deliverables] POST error:', err);
    return Response.json({ error: 'Failed to create deliverable' }, { status: 500 });
  }
}

// PATCH /api/deliverables — update status or write QA criterion results
export async function PATCH(request: NextRequest) {
  let body: Record<string, unknown>;
  try { body = await request.json(); } catch {
    return Response.json({ error: 'Invalid JSON' }, { status: 400 });
  }

  const { id, status, criterion_updates, sign_off_by } = body as Record<string, unknown>;
  if (!id || typeof id !== 'string') return Response.json({ error: 'id required' }, { status: 400 });

  // Fail loud on no-op: if none of the recognized write fields are present, reject rather than silently succeed
  if (criterion_updates === undefined && status === undefined && sign_off_by === undefined) {
    const known = ['id', 'criterion_updates', 'status', 'sign_off_by'];
    const unknown = Object.keys(body).filter(k => !known.includes(k));
    return Response.json({
      error: 'No recognized fields to apply. Known fields: criterion_updates, status, sign_off_by',
      unknown_fields: unknown,
    }, { status: 400 });
  }

  // sign_off_by without status:"signed_off" is always a no-op — reject loud
  if (sign_off_by !== undefined && status !== 'signed_off') {
    return Response.json({
      error: 'sign_off_by requires status:"signed_off" in the same request — standalone sign_off_by has no effect',
    }, { status: 400 });
  }

  const row = db.prepare('SELECT * FROM deliverables WHERE id = ?').get(id) as DeliverableRow | undefined;
  if (!row) return Response.json({ error: 'Deliverable not found' }, { status: 404 });

  const sow = db.prepare('SELECT accepting_owner FROM sows WHERE id = ?').get(row.sow_id) as { accepting_owner: string } | undefined;
  const acceptingOwner = sow?.accepting_owner || 'pmo';

  let criteria = JSON.parse(row.success_criteria || '[]') as Criterion[];
  const now = new Date().toISOString();

  // Apply criterion result updates (QA writes)
  if (Array.isArray(criterion_updates)) {
    for (const upd of criterion_updates as { id: string; result: string; verified_by: string }[]) {
      if (!VALID_CRITERION_RESULTS.includes(upd.result)) {
        return Response.json({ error: `Invalid result '${upd.result}' for criterion ${upd.id}` }, { status: 400 });
      }
      // Prover ≠ verifier enforcement
      if (upd.result !== 'pending' && upd.verified_by === row.owner_agent) {
        return Response.json({
          error: `Integrity violation: criterion ${upd.id} — verified_by must differ from owner_agent (${row.owner_agent})`,
          integrity_violation: true,
        }, { status: 422 });
      }
      criteria = criteria.map(c =>
        c.id === upd.id ? { ...c, result: upd.result, verified_by: upd.verified_by ?? c.verified_by } : c
      );
    }
  }

  // Run integrity check on full criteria set
  const violations = checkIntegrity(criteria, row.owner_agent);
  if (violations.length > 0) {
    return Response.json({ error: 'Integrity violations', violations, integrity_violation: true }, { status: 422 });
  }

  let newStatus = row.status;
  if (status) {
    if (!VALID_STATUSES.includes(status as string)) {
      return Response.json({ error: `Invalid status. Must be: ${VALID_STATUSES.join(', ')}` }, { status: 400 });
    }

    // qa_passed requires all criteria pass
    if (status === 'qa_passed') {
      const failing = criteria.filter(c => c.result !== 'pass');
      if (failing.length > 0) {
        return Response.json({
          error: 'Cannot set qa_passed — not all criteria have result=pass',
          pending_criteria: failing.map(c => c.id),
        }, { status: 422 });
      }
    }

    // signed_off requires qa_passed first
    if (status === 'signed_off') {
      if (row.status !== 'qa_passed' && newStatus !== 'qa_passed') {
        return Response.json({ error: 'Cannot sign off — deliverable must be qa_passed first' }, { status: 422 });
      }
      // signed_off_by must equal accepting_owner
      if (!sign_off_by || sign_off_by !== acceptingOwner) {
        return Response.json({
          error: `signed_off_by must equal accepting_owner (${acceptingOwner})`,
          accepting_owner: acceptingOwner,
        }, { status: 422 });
      }
    }

    newStatus = status as string;
  }

  const signedOffAt = newStatus === 'signed_off' ? now : row.signed_off_at;
  const signedOffBy = newStatus === 'signed_off' ? (sign_off_by as string) : row.signed_off_by;
  const lastRun = criterion_updates ? now : row.last_run;
  const attempts = criterion_updates ? row.attempts + 1 : row.attempts;

  db.prepare(`
    UPDATE deliverables
    SET success_criteria = ?, status = ?, signed_off_by = ?, signed_off_at = ?,
        attempts = ?, last_run = ?, updated_at = ?
    WHERE id = ?
  `).run(JSON.stringify(criteria), newStatus, signedOffBy, signedOffAt, attempts, lastRun, now, id);

  const updated = db.prepare('SELECT * FROM deliverables WHERE id = ?').get(id) as DeliverableRow;
  return Response.json(parseDeliverable(updated));
}
