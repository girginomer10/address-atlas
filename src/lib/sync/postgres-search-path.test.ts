import { describe, expect, it } from "vitest";
import {
  assertSafeRestoreDatabaseContext,
  PRODUCTION_POOL_OPTIONS,
  type RestoreDatabaseContext
} from "./postgres-search-path";

const safeContext: RestoreDatabaseContext = {
  current_user: "address_atlas",
  session_user: "address_atlas",
  current_schema: "public",
  configured_search_path: "public",
  explicit_schemas: ["public"],
  effective_schemas: ["pg_catalog", "public"],
  spoof_schema_count: 0
};

describe("production PostgreSQL search path", () => {
  it("keeps pg_catalog implicit and therefore ahead of public", () => {
    expect(PRODUCTION_POOL_OPTIONS).toBe("-csearch_path=public");
    expect(() => assertSafeRestoreDatabaseContext(safeContext, 1)).not.toThrow();
  });

  it.each([
    ["wrong owner", { current_user: "address_atlas_runtime" }],
    ["wrong session owner", { session_user: "address_atlas_admin" }],
    ["wrong current schema", { current_schema: "pg_catalog" }],
    ["non-canonical configured value", { configured_search_path: " public" }],
    ["user-dependent configured value", { configured_search_path: "$user,public" }],
    [
      "catalog made explicit after public",
      {
        configured_search_path: "public,pg_catalog",
        explicit_schemas: ["public", "pg_catalog"],
        effective_schemas: ["public", "pg_catalog"]
      }
    ],
    ["unexpected explicit schema", { explicit_schemas: ["address_atlas", "public"] }],
    ["unsafe effective order", { effective_schemas: ["public", "pg_catalog"] }],
    ["temporary schema in the effective path", {
      effective_schemas: ["pg_temp_3", "pg_catalog", "public"]
    }],
    ["owner-named spoof schema", { spoof_schema_count: 1 }]
  ])("rejects %s", (_label, override) => {
    expect(() => assertSafeRestoreDatabaseContext(
      { ...safeContext, ...override },
      1
    )).toThrow(/owner\/search-path context is unsafe/i);
  });

  it("rejects a missing or duplicated context row", () => {
    expect(() => assertSafeRestoreDatabaseContext(undefined, 0)).toThrow(/unsafe/i);
    expect(() => assertSafeRestoreDatabaseContext(safeContext, 2)).toThrow(/unsafe/i);
  });
});
