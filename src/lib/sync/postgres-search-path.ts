export const PRODUCTION_SEARCH_PATH_SETTING = "public";
export const PRODUCTION_POOL_OPTIONS = `-csearch_path=${PRODUCTION_SEARCH_PATH_SETTING}`;

const PRODUCTION_EXPLICIT_SCHEMAS = ["public"] as const;
const PRODUCTION_EFFECTIVE_SCHEMAS = ["pg_catalog", "public"] as const;

export const RESTORE_DATABASE_CONTEXT_QUERY = `
  SELECT
    current_user::pg_catalog.text AS current_user,
    session_user::pg_catalog.text AS session_user,
    pg_catalog.current_schema()::pg_catalog.text AS current_schema,
    pg_catalog.current_setting('search_path') AS configured_search_path,
    pg_catalog.current_schemas(false)::pg_catalog.text[] AS explicit_schemas,
    pg_catalog.current_schemas(true)::pg_catalog.text[] AS effective_schemas,
    (
      SELECT pg_catalog.count(*)::pg_catalog.int4
      FROM pg_catalog.pg_namespace
      WHERE nspname OPERATOR(pg_catalog.=) 'address_atlas'
    ) AS spoof_schema_count
`;

export interface RestoreDatabaseContext {
  current_user: string;
  session_user: string;
  current_schema: string | null;
  configured_search_path: string;
  explicit_schemas: string[];
  effective_schemas: string[];
  spoof_schema_count: number;
}

/**
 * The catalog must stay implicit. PostgreSQL then searches pg_catalog before
 * public while keeping public as current_schema() for unqualified application
 * objects. Explicit `public,pg_catalog` reverses that safe function lookup.
 */
export function assertSafeRestoreDatabaseContext(
  row: RestoreDatabaseContext | undefined,
  rowCount: number | null
) {
  if (
    rowCount !== 1
    || !row
    || row.current_user !== "address_atlas"
    || row.session_user !== "address_atlas"
    || row.current_schema !== "public"
    || row.configured_search_path !== PRODUCTION_SEARCH_PATH_SETTING
    || !sameOrderedMembers(row.explicit_schemas, PRODUCTION_EXPLICIT_SCHEMAS)
    || !sameOrderedMembers(row.effective_schemas, PRODUCTION_EFFECTIVE_SCHEMAS)
    || row.spoof_schema_count !== 0
  ) {
    throw new Error("Restored database owner/search-path context is unsafe.");
  }
}

function sameOrderedMembers(
  actual: readonly string[],
  expected: readonly string[]
) {
  return Array.isArray(actual)
    && actual.length === expected.length
    && actual.every((value, index) => value === expected[index]);
}
