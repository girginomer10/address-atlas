import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import {
  assertExchangeProvider,
  credentialsFromInput,
  exchangeProviderLabel,
  EXCHANGE_PROVIDERS,
  testExchangeCredentials
} from "@/lib/exchanges";
import { encryptForVault, hasVault } from "@/lib/security";
import { ExchangeCredentialInput } from "@/lib/types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    const connections = await prisma.exchangeConnection.findMany({
      orderBy: {
        createdAt: "asc"
      }
    });

    return NextResponse.json({
      providers: EXCHANGE_PROVIDERS,
      vaultReady: await hasVault(),
      connections: connections.map((connection) => ({
        id: connection.id,
        provider: connection.provider,
        providerLabel: exchangeProviderLabel(connection.provider),
        label: connection.label,
        status: connection.status,
        lastTestedAt: connection.lastTestedAt?.toISOString(),
        lastSyncAt: connection.lastSyncAt?.toISOString(),
        lastError: connection.lastError
      }))
    });
  } catch (error) {
    return errorResponse(error, "Exchange connections could not be loaded.");
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as ExchangeCredentialInput;
    assertExchangeProvider(body.provider);
    if (!body.vaultPassphrase) {
      return NextResponse.json({ error: "Vault passphrase is required." }, { status: 400 });
    }

    const credentials = credentialsFromInput(body);
    const test = await testExchangeCredentials(body);
    const encryptedCredentials = await encryptForVault(credentials, body.vaultPassphrase);
    const connection = await prisma.exchangeConnection.create({
      data: {
        provider: body.provider,
        label: body.label?.trim() || exchangeProviderLabel(body.provider),
        encryptedCredentials,
        status: "ok",
        lastTestedAt: new Date()
      }
    });

    return NextResponse.json({
      ok: true,
      test,
      connection: {
        id: connection.id,
        provider: connection.provider,
        providerLabel: exchangeProviderLabel(connection.provider),
        label: connection.label,
        status: connection.status,
        lastTestedAt: connection.lastTestedAt?.toISOString()
      }
    });
  } catch (error) {
    return errorResponse(error, "Exchange connection could not be saved.");
  }
}

export async function DELETE(request: NextRequest) {
  try {
    const id = request.nextUrl.searchParams.get("id");
    if (!id) return NextResponse.json({ error: "Exchange connection id is required." }, { status: 400 });

    await prisma.exchangeConnection.delete({
      where: {
        id
      }
    });

    return NextResponse.json({ ok: true });
  } catch (error) {
    return errorResponse(error, "Exchange connection could not be removed.");
  }
}

function errorResponse(error: unknown, fallback: string) {
  return NextResponse.json(
    {
      error: fallback,
      details: error instanceof Error ? error.message : "Unknown error"
    },
    { status: 500 }
  );
}
