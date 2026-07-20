/**
 * Compatibility facade for sync persistence. Runtime pool lifecycle and
 * readiness orchestration live in postgres-runtime; schema DDL and contract
 * reconciliation live in postgres-schema.
 */
export {
  bootstrapSyncSchema,
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  closeSyncPools,
  ensureSyncSchema,
  getSyncPool
} from "./postgres-runtime";
