import { NextRequest, NextResponse } from "next/server";
import {
  createManualHolding,
  deleteManualHolding,
  listManualHoldings,
  manualProviderOptions,
  updateManualHolding
} from "@/lib/manual-exchanges";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    return NextResponse.json({
      providers: manualProviderOptions(),
      holdings: await listManualHoldings()
    });
  } catch (error) {
    return errorResponse(error, "Manual exchange entries could not be loaded.", 500);
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
    const holding = await createManualHolding(body);
    return NextResponse.json({ ok: true, holding });
  } catch (error) {
    return errorResponse(error, "Manual exchange entry could not be saved.", 400);
  }
}

export async function PATCH(request: NextRequest) {
  try {
    const body = (await request.json().catch(() => ({}))) as { id?: string } & Record<string, unknown>;
    const id = typeof body.id === "string" ? body.id : "";
    if (!id) {
      return NextResponse.json({ error: "Manual holding id is required." }, { status: 400 });
    }

    const { id: _omit, ...rest } = body;
    void _omit;
    const holding = await updateManualHolding(id, rest);
    return NextResponse.json({ ok: true, holding });
  } catch (error) {
    return errorResponse(error, "Manual exchange entry could not be updated.", 400);
  }
}

export async function DELETE(request: NextRequest) {
  try {
    const id = request.nextUrl.searchParams.get("id");
    if (!id) {
      return NextResponse.json({ error: "Manual holding id is required." }, { status: 400 });
    }
    await deleteManualHolding(id);
    return NextResponse.json({ ok: true });
  } catch (error) {
    return errorResponse(error, "Manual exchange entry could not be removed.", 400);
  }
}

function errorResponse(error: unknown, fallback: string, status: number) {
  return NextResponse.json(
    {
      error: fallback,
      details: error instanceof Error ? error.message : "Unknown error"
    },
    { status }
  );
}
