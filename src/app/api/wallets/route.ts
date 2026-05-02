import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { assertSafePublicAddresses, defaultWalletLabel, detectAddressKind, isSupportedPublicAddress } from "@/lib/address-utils";
import { listWallets } from "@/lib/local-store";
import { parseAddressInput } from "@/lib/scanner";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    return NextResponse.json({ wallets: await listWallets() });
  } catch (error) {
    return errorResponse(error, "Wallets could not be loaded.");
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as { address?: string; label?: string };
    const addresses = parseAddressInput(body.address ?? "");
    assertSafePublicAddresses(addresses);

    if (addresses.length !== 1) {
      return NextResponse.json({ error: "Exactly one public wallet address is required." }, { status: 400 });
    }

    const address = addresses[0];
    if (!isSupportedPublicAddress(address)) {
      return NextResponse.json({ error: "A supported public wallet address is required." }, { status: 400 });
    }

    const wallet = await prisma.walletAddress.upsert({
      where: { address },
      create: {
        address,
        label: body.label?.trim() || defaultWalletLabel(address),
        chainKind: detectAddressKind(address)
      },
      update: {
        label: body.label?.trim() || undefined,
        chainKind: detectAddressKind(address)
      }
    });

    return NextResponse.json({ wallet });
  } catch (error) {
    return errorResponse(error, "Wallet could not be saved.");
  }
}

export async function PATCH(request: NextRequest) {
  try {
    const body = (await request.json()) as { id?: string; label?: string };
    if (!body.id || !body.label?.trim()) {
      return NextResponse.json({ error: "Wallet id and label are required." }, { status: 400 });
    }

    const wallet = await prisma.walletAddress.update({
      where: {
        id: body.id
      },
      data: {
        label: body.label.trim()
      }
    });

    return NextResponse.json({ wallet });
  } catch (error) {
    return errorResponse(error, "Wallet could not be updated.");
  }
}

export async function DELETE(request: NextRequest) {
  try {
    const id = request.nextUrl.searchParams.get("id");
    if (!id) return NextResponse.json({ error: "Wallet id is required." }, { status: 400 });

    await prisma.walletAddress.delete({
      where: {
        id
      }
    });

    return NextResponse.json({ ok: true });
  } catch (error) {
    return errorResponse(error, "Wallet could not be removed.");
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
