import { Pool } from 'pg';

const globalForPool = globalThis as unknown as { __orbfutures_pool: Pool | undefined };

export const orbPool =
  globalForPool.__orbfutures_pool ??
  new Pool({
    connectionString:
      process.env.ORBFUTURES_DATABASE_URL ??
      'postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard',
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
  });

if (process.env.NODE_ENV !== 'production') {
  globalForPool.__orbfutures_pool = orbPool;
}
