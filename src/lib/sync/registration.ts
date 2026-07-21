import type { PoolClient } from "pg";
import { getSyncRegistrationConfig } from "./config";
import { ensureSyncSchema, getSyncPool } from "./postgres";

export class RegistrationDisabledError extends Error {
  constructor() {
    super("New account registration is currently closed.");
    this.name = "RegistrationDisabledError";
  }
}

export class RegistrationAdmissionQuotaError extends Error {
  constructor() {
    super("Registration capacity is temporarily unavailable.");
    this.name = "RegistrationAdmissionQuotaError";
  }
}

export function assertRegistrationEnabled() {
  if (!getSyncRegistrationConfig().enabled) throw new RegistrationDisabledError();
}

/**
 * Reserve one globally durable hourly registration admission. The atomic
 * upsert survives process restarts and remains exact across replicas.
 */
export async function reserveRegistrationAdmission(
  database?: Pick<PoolClient, "query">
) {
  const { enabled, hourlyLimit } = getSyncRegistrationConfig();
  if (!enabled) throw new RegistrationDisabledError();
  if (!database) await ensureSyncSchema();
  const result = await (database ?? getSyncPool()).query(
    `WITH pruned AS (
       DELETE FROM registration_usage
       WHERE window_started_at < now() - interval '48 hours'
     )
     INSERT INTO registration_usage (window_started_at, admission_count)
     VALUES (
       date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
       1
     )
     ON CONFLICT (window_started_at) DO UPDATE SET
       admission_count = registration_usage.admission_count + 1,
       updated_at = now()
     WHERE registration_usage.admission_count < $1
     RETURNING admission_count`,
    [hourlyLimit]
  );
  if (result.rowCount === 0) throw new RegistrationAdmissionQuotaError();
}
