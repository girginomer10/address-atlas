import { NextRequest, NextResponse } from "next/server";
import { assertNoPlaintextLeak, assertRemoteVaultSnapshot } from "@/lib/sync/envelope";
import { ensureSyncSchema, getSyncPool } from "@/lib/sync/postgres";
import { readBearerToken } from "@/lib/sync/tokens";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const session = readBearerToken(request.headers.get("authorization"));
    await ensureSyncSchema();
    const result = await getSyncPool().query<{
      version: number;
      envelope: unknown;
      byte_size: number;
      checksum: string;
      updated_at: Date;
    }>(
      "SELECT version, envelope, byte_size, checksum, updated_at FROM vault_snapshots WHERE user_id = $1",
      [session.userId]
    );
    const row = result.rows[0];
    if (!row) return NextResponse.json({ error: "No vault snapshot." }, { status: 404 });
    return NextResponse.json({
      version: row.version,
      envelope: row.envelope,
      byteSize: row.byte_size,
      checksum: row.checksum,
      updatedAt: row.updated_at.toISOString()
    });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Vault snapshot could not be loaded." },
      { status: isAuthError(error) ? 401 : 500 }
    );
  }
}

export async function PUT(request: NextRequest) {
  try {
    const session = readBearerToken(request.headers.get("authorization"));
    const body = await request.json().catch(() => ({}));
    assertRemoteVaultSnapshot(body);
    assertNoPlaintextLeak(body);
    await ensureSyncSchema();
    const result = await getSyncPool().query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, $2, $3::jsonb, $4, $5)
       ON CONFLICT (user_id) DO UPDATE SET
         version = excluded.version,
         envelope = excluded.envelope,
         byte_size = excluded.byte_size,
         checksum = excluded.checksum,
         updated_at = now()
       WHERE vault_snapshots.version < excluded.version
          OR (
            vault_snapshots.version = excluded.version
            AND vault_snapshots.checksum = excluded.checksum
          )
       RETURNING version`,
      [session.userId, body.version, JSON.stringify(body.envelope), body.byteSize, body.checksum]
    );
    if (result.rowCount === 0) {
      return NextResponse.json(
        { error: "Remote vault snapshot is newer. Download before uploading again." },
        { status: 409 }
      );
    }
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Vault snapshot could not be saved." },
      { status: isAuthError(error) ? 401 : 400 }
    );
  }
}

function isAuthError(error: unknown) {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  return message.includes("authorization")
    || message.includes("token")
    || message.includes("signature")
    || message.includes("expired");
}
