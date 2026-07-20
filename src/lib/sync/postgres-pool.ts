import { Pool } from "pg";
import { getSyncDatabaseConfig, getSyncSchemaDatabaseConfig } from "./config";
import { generatedDiagnostics, recordSecurityEvent } from "./diagnostics";

let runtimePool: Pool | null = null;
let schemaPool: Pool | null = null;

function createPool(
  config: ReturnType<typeof getSyncDatabaseConfig>,
  applicationName: string,
  max: number,
  diagnosticSource: string,
  failureReason: string
) {
  const created = new Pool({
    connectionString: config.connectionString,
    application_name: applicationName,
    max,
    connectionTimeoutMillis: config.connectTimeoutMs,
    idleTimeoutMillis: config.idleTimeoutMs,
    statement_timeout: config.statementTimeoutMs,
    query_timeout: config.queryTimeoutMs
  });
  // node-postgres emits pool-level errors for idle clients that lose their
  // backend connection. Always consume the event so a DB restart cannot turn
  // into an uncaught EventEmitter error and terminate the process.
  created.on("error", () => {
    recordSecurityEvent("database.connection_failed", generatedDiagnostics(diagnosticSource), {
      status: 503,
      reason: failureReason,
      severity: "error"
    });
  });
  return created;
}

export function getSyncPool() {
  if (!runtimePool) {
    const config = getSyncDatabaseConfig();
    runtimePool = createPool(
      config,
      "address-atlas-sync",
      config.poolSize,
      "postgres.pool",
      "idle_connection_failed"
    );
  }
  return runtimePool;
}

/** Reserved for the one-shot bootstrap command; request paths never call it. */
export function getSyncSchemaPool() {
  if (!schemaPool) {
    const config = getSyncSchemaDatabaseConfig();
    schemaPool = createPool(
      config,
      "address-atlas-schema-bootstrap",
      1,
      "postgres.schema_pool",
      "schema_connection_failed"
    );
  }
  return schemaPool;
}

export async function closeSyncDatabasePools() {
  await Promise.all([runtimePool?.end(), schemaPool?.end()]);
  runtimePool = null;
  schemaPool = null;
}
