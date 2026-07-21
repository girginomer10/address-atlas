import { Suspense } from "react";
import { NativePasskeyBridge } from "./NativePasskeyBridge";

export const dynamic = "force-dynamic";

export default async function NativeAuthPage({
  searchParams
}: {
  searchParams: Promise<{
    callback?: string | string[];
    state?: string | string[];
    mode?: string | string[];
    code_challenge?: string | string[];
    code_challenge_method?: string | string[];
  }>;
}) {
  const params = await searchParams;
  const callback = typeof params.callback === "string" ? params.callback : "";
  const state = typeof params.state === "string" ? params.state : "";
  const codeChallenge = typeof params.code_challenge === "string" ? params.code_challenge : "";
  const codeChallengeMethod = typeof params.code_challenge_method === "string"
    ? params.code_challenge_method
    : "";
  const mode = params.mode === "register" || params.mode === "authenticate" ? params.mode : null;
  return (
    <Suspense>
      <NativePasskeyBridge
        callback={callback}
        state={state}
        codeChallenge={codeChallenge}
        codeChallengeMethod={codeChallengeMethod}
        mode={mode}
      />
    </Suspense>
  );
}
