/**
 * SessionEnd hook — scrape token usage from the JSONL transcript and store it.
 * Reads the agent's most recent Claude Code session JSONL, sums token counts,
 * and writes to the cortextos usage state store.
 */
import { readFileSync, readdirSync, existsSync, writeFileSync, appendFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

interface TokenTotals {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
}

function findProjectDir(agentName: string): string | null {
  const claudeProjects = join(homedir(), '.claude', 'projects');
  if (!existsSync(claudeProjects)) return null;

  // Agent project dirs are named by slugifying the working directory path.
  // Look for dirs that end with the agent name slug.
  const slug = agentName.replace(/_/g, '-');
  try {
    const dirs = readdirSync(claudeProjects);
    const match = dirs.find((d) => d.endsWith(`-agents-${slug}`));
    return match ? join(claudeProjects, match) : null;
  } catch {
    return null;
  }
}

function getMostRecentJSONL(dir: string): string | null {
  try {
    const files = readdirSync(dir)
      .filter((f) => f.endsWith('.jsonl'))
      .map((f) => ({ name: f, path: join(dir, f) }))
      .sort((a, b) => {
        try {
          const sa = readFileSync(a.path).length;
          const sb = readFileSync(b.path).length;
          return sb - sa; // largest (most recent active) first
        } catch {
          return 0;
        }
      });
    return files[0]?.path ?? null;
  } catch {
    return null;
  }
}

function sumTokens(jsonlPath: string): TokenTotals {
  const totals: TokenTotals = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
  };

  try {
    const lines = readFileSync(jsonlPath, 'utf-8').split('\n').filter(Boolean);
    for (const line of lines) {
      try {
        const d = JSON.parse(line);
        const usage = d?.message?.usage;
        if (!usage) continue;
        totals.input_tokens += usage.input_tokens ?? 0;
        totals.output_tokens += usage.output_tokens ?? 0;
        totals.cache_creation_input_tokens += usage.cache_creation_input_tokens ?? 0;
        totals.cache_read_input_tokens += usage.cache_read_input_tokens ?? 0;
      } catch {
        // skip malformed lines
      }
    }
  } catch {
    // ignore read errors
  }

  return totals;
}

async function main(): Promise<void> {
  const agentName = process.env.CTX_AGENT_NAME;
  const instanceId = process.env.CTX_INSTANCE_ID || 'default';
  if (!agentName) return;

  const ctxRoot = join(homedir(), '.cortextos', instanceId);
  const usageDir = join(ctxRoot, 'state', 'usage');
  mkdirSync(usageDir, { recursive: true });

  const projectDir = findProjectDir(agentName);
  if (!projectDir) return;

  const jsonlPath = getMostRecentJSONL(projectDir);
  if (!jsonlPath) return;

  const tokens = sumTokens(jsonlPath);
  const timestamp = new Date().toISOString();
  const today = timestamp.split('T')[0];

  const record = {
    agent: agentName,
    timestamp,
    tokens,
    session: { used_pct: 0, resets: '' },
    week_all_models: { used_pct: 0, resets: '' },
    week_sonnet: { used_pct: 0 },
  };

  // Write latest
  writeFileSync(join(usageDir, 'latest.json'), JSON.stringify(record, null, 2) + '\n', 'utf-8');

  // Append to per-agent daily log
  const dailyPath = join(usageDir, `${agentName}-${today}.jsonl`);
  const line = JSON.stringify(record) + '\n';
  try {
    appendFileSync(dailyPath, line, 'utf-8');
  } catch {
    writeFileSync(dailyPath, line, 'utf-8');
  }
}

main().catch(() => process.exit(0));
