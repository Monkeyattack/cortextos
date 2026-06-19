import { NextRequest } from 'next/server';
import { db } from '@/lib/db';

export const dynamic = 'force-dynamic';

interface Criterion {
  id: string;
  statement: string;
  result: string;
  verified_by: string | null;
}

interface DeliverableRow {
  id: string;
  title: string;
  owner_agent: string;
  status: string;
  success_criteria: string;
  signed_off_by: string | null;
  signed_off_at: string | null;
}

interface SOWRow {
  id: string;
  project: string;
  consumer: string;
  accepting_owner: string;
  objective: string;
  background: string;
  in_scope: string;
  out_of_scope: string;
  constraints: string;
  deliverable_ids: string;
  status: string;
  release_note_id: string | null;
  org: string;
  created_at: string;
  updated_at: string;
}

function computeRollup(sowId: string, acceptingOwner: string) {
  const deliverables = db.prepare('SELECT * FROM deliverables WHERE sow_id = ?').all(sowId) as DeliverableRow[];
  const counts: Record<string, number> = {
    not_started: 0, in_progress: 0, needs_qa: 0, qa_failed: 0, qa_passed: 0, signed_off: 0,
  };
  let integrityViolations = 0;

  for (const d of deliverables) {
    counts[d.status] = (counts[d.status] || 0) + 1;
    const criteria = JSON.parse(d.success_criteria || '[]') as Criterion[];
    for (const c of criteria) {
      if (c.result !== 'pending' && c.verified_by === d.owner_agent) integrityViolations++;
      if (c.result !== 'pending' && !c.verified_by) integrityViolations++;
    }
    // signed_off_by must equal accepting_owner
    if (d.status === 'signed_off' && d.signed_off_by !== acceptingOwner) integrityViolations++;
  }

  const complete = deliverables.length > 0 &&
    counts.signed_off === deliverables.length &&
    integrityViolations === 0;

  return {
    total: deliverables.length,
    not_started: counts.not_started,
    in_progress: counts.in_progress,
    needs_qa: counts.needs_qa,
    qa_failed: counts.qa_failed,
    qa_passed: counts.qa_passed,
    signed_off: counts.signed_off,
    integrity_violations: integrityViolations,
    complete,
  };
}

// GET /api/sows/:id — SOW detail + rollup
export async function GET(_request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const sow = db.prepare('SELECT * FROM sows WHERE id = ?').get(id) as SOWRow | undefined;
  if (!sow) return Response.json({ error: 'SOW not found' }, { status: 404 });

  const deliverables = db.prepare('SELECT * FROM deliverables WHERE sow_id = ?').all(id) as DeliverableRow[];
  const rollup = computeRollup(id, sow.accepting_owner);

  return Response.json({
    ...sow,
    in_scope: JSON.parse(sow.in_scope || '[]'),
    out_of_scope: JSON.parse(sow.out_of_scope || '[]'),
    deliverable_ids: JSON.parse(sow.deliverable_ids || '[]'),
    deliverables: deliverables.map(d => ({
      ...d,
      success_criteria: JSON.parse(d.success_criteria || '[]'),
    })),
    rollup,
  });
}

// POST /api/sows/:id/release-note — emit release note when complete
export async function POST(_request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const sow = db.prepare('SELECT * FROM sows WHERE id = ?').get(id) as SOWRow | undefined;
  if (!sow) return Response.json({ error: 'SOW not found' }, { status: 404 });

  const rollup = computeRollup(id, sow.accepting_owner);
  if (!rollup.complete) {
    return Response.json({
      error: 'Release note blocked — SOW not complete',
      rollup,
    }, { status: 422 });
  }

  const deliverables = db.prepare('SELECT * FROM deliverables WHERE sow_id = ?').all(id) as DeliverableRow[];
  const releaseNoteId = `RN-${id}-${Date.now()}`;
  const now = new Date().toISOString();

  const noteContent = [
    `# Release Note — ${sow.project}`,
    `**SOW:** ${id}  `,
    `**Consumer:** ${sow.consumer}  `,
    `**Issued:** ${now}  `,
    `**Accepting Owner:** ${sow.accepting_owner}  `,
    ``,
    `## Objective`,
    sow.objective,
    ``,
    `## Deliverables`,
    ...deliverables.map(d => `- ✓ **${d.title}** — signed off by ${d.signed_off_by} at ${d.signed_off_at}`),
    ``,
    `## Integrity`,
    `Violations: ${rollup.integrity_violations}  `,
    `All deliverables signed off: ${rollup.signed_off}/${rollup.total}`,
  ].join('\n');

  db.prepare('UPDATE sows SET release_note_id = ?, status = ?, updated_at = ? WHERE id = ?')
    .run(releaseNoteId, 'complete', now, id);

  return Response.json({ release_note_id: releaseNoteId, content: noteContent, issued_at: now });
}
