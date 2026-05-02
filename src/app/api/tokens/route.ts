import { NextRequest, NextResponse } from "next/server";
import { EVM_CHAINS } from "@/lib/chain-registry";
import {
  CustomTokenInput,
  CustomTokenUpdate,
  CustomTokenValidationError,
  createCustomToken,
  deleteCustomToken,
  listCustomTokens,
  updateCustomToken
} from "@/lib/local-store";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const CHAIN_OPTIONS = EVM_CHAINS.map((chain) => ({
  id: chain.id,
  name: chain.name,
  family: chain.family
}));

export async function GET() {
  try {
    return NextResponse.json({
      tokens: await listCustomTokens(),
      chainOptions: CHAIN_OPTIONS
    });
  } catch (error) {
    return errorResponse(error, "Custom tokens could not be loaded.");
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as CustomTokenInput;
    const token = await createCustomToken(body);
    return NextResponse.json({ token });
  } catch (error) {
    return validationOrError(error, "Custom token could not be created.");
  }
}

export async function PATCH(request: NextRequest) {
  try {
    const body = (await request.json()) as CustomTokenUpdate & { id?: string };
    if (!body.id) {
      return NextResponse.json({ error: "Token id is required." }, { status: 400 });
    }
    const { id, ...rest } = body;
    const token = await updateCustomToken(id, rest);
    return NextResponse.json({ token });
  } catch (error) {
    return validationOrError(error, "Custom token could not be updated.");
  }
}

export async function DELETE(request: NextRequest) {
  try {
    const id = request.nextUrl.searchParams.get("id");
    if (!id) {
      return NextResponse.json({ error: "Token id is required." }, { status: 400 });
    }
    await deleteCustomToken(id);
    return NextResponse.json({ ok: true });
  } catch (error) {
    return validationOrError(error, "Custom token could not be removed.");
  }
}

function validationOrError(error: unknown, fallback: string) {
  if (error instanceof CustomTokenValidationError) {
    return NextResponse.json({ error: error.message, field: error.field }, { status: 400 });
  }
  return errorResponse(error, fallback);
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
