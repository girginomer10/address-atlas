import { Suspense } from "react";
import { NativePasskeyBridge } from "./NativePasskeyBridge";

export const dynamic = "force-dynamic";

export default async function NativeAuthPage({
  searchParams
}: {
  searchParams: Promise<{ callback?: string; state?: string }>;
}) {
  const params = await searchParams;
  return (
    <Suspense>
      <NativePasskeyBridge callback={params.callback || ""} state={params.state || ""} />
    </Suspense>
  );
}
