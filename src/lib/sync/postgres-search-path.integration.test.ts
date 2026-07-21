import { randomUUID } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  assertSafeRestoreDatabaseContext,
  PRODUCTION_POOL_OPTIONS,
  RESTORE_DATABASE_CONTEXT_QUERY,
  type RestoreDatabaseContext
} from "./postgres-search-path";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("production PostgreSQL search-path integration", () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({
      connectionString: process.env.TEST_SYNC_DATABASE_URL,
      options: PRODUCTION_POOL_OPTIONS,
      max: 1
    });
  });

  afterAll(async () => {
    await pool?.end();
  });

  it("matches the exact restore owner and effective catalog-first path", async () => {
    const context = await pool.query<RestoreDatabaseContext>(
      RESTORE_DATABASE_CONTEXT_QUERY
    );
    expect(() => assertSafeRestoreDatabaseContext(
      context.rows[0],
      context.rowCount
    )).not.toThrow();
  });

  it("keeps implicit pg_catalog functions ahead of a writable schema", async () => {
    const client = await pool.connect();
    const shadowSchema = `restore_shadow_${randomUUID().replaceAll("-", "")}`;
    try {
      await client.query("BEGIN");
      await client.query(`CREATE SCHEMA "${shadowSchema}"`);
      await client.query(`
        CREATE FUNCTION "${shadowSchema}".current_setting(pg_catalog.text)
        RETURNS pg_catalog.text
        LANGUAGE sql
        IMMUTABLE
        AS $body$ SELECT 'spoofed'::pg_catalog.text $body$
      `);
      await client.query(`SET LOCAL search_path TO "${shadowSchema}"`);
      const result = await client.query<{
        unqualified_result: string;
        catalog_result: string;
      }>(`
        SELECT
          current_setting('search_path') AS unqualified_result,
          pg_catalog.current_setting('search_path') AS catalog_result
      `);
      expect(result.rows[0]?.unqualified_result).toBe(result.rows[0]?.catalog_result);
      expect(result.rows[0]?.unqualified_result).not.toBe("spoofed");

      await client.query(`SET LOCAL search_path TO "${shadowSchema}", pg_catalog`);
      const unsafeResult = await client.query<{
        unqualified_result: string;
        catalog_result: string;
      }>(`
        SELECT
          current_setting('search_path') AS unqualified_result,
          pg_catalog.current_setting('search_path') AS catalog_result
      `);
      expect(unsafeResult.rows[0]?.unqualified_result).toBe("spoofed");
      expect(unsafeResult.rows[0]?.catalog_result).not.toBe("spoofed");

      const unsafeContext = await client.query<RestoreDatabaseContext>(
        RESTORE_DATABASE_CONTEXT_QUERY
      );
      expect(unsafeContext.rows[0]?.configured_search_path).not.toBe("spoofed");
      expect(() => assertSafeRestoreDatabaseContext(
        unsafeContext.rows[0],
        unsafeContext.rowCount
      )).toThrow(/owner\/search-path context is unsafe/i);
    } finally {
      await client.query("ROLLBACK");
      client.release();
    }
  });
});
