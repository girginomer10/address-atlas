"use client";

import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import type {
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON
} from "@simplewebauthn/browser";
import { useMemo, useState } from "react";

type Mode = "register" | "authenticate";

type OptionsResponse = {
  mode: Mode;
  challengeToken: string;
  publicKey: PublicKeyCredentialCreationOptionsJSON | PublicKeyCredentialRequestOptionsJSON;
  error?: string;
};

type VerifyResponse = {
  verified?: boolean;
  userId?: string;
  sessionToken?: string;
  error?: string;
};

export function NativePasskeyBridge({
  callback,
  state,
  mode
}: {
  callback: string;
  state: string;
  mode: Mode | null;
}) {
  const [accountName, setAccountName] = useState("");
  const [busy, setBusy] = useState<Mode | null>(null);
  const [message, setMessage] = useState("");
  const canReturn = useMemo(() => {
    try {
      const url = new URL(callback);
      return url.protocol === "address-atlas:"
        && url.hostname === "sync-auth"
        && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(state);
    } catch {
      return false;
    }
  }, [callback, state]);

  async function run() {
    if (!mode) {
      setMessage("A valid passkey action is required.");
      return;
    }
    setBusy(mode);
    setMessage("");
    try {
      if (!canReturn) {
        throw new Error("Native return URL is missing.");
      }
      const optionsResponse = await fetch("/auth/passkey/options", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          mode,
          accountName: accountName.trim() || undefined
        })
      });
      const options = (await optionsResponse.json()) as OptionsResponse;
      if (!optionsResponse.ok || options.error) {
        throw new Error(options.error || "Passkey options failed.");
      }

      const response =
        mode === "register"
          ? await startRegistration({
              optionsJSON: options.publicKey as PublicKeyCredentialCreationOptionsJSON
            })
          : await startAuthentication({
              optionsJSON: options.publicKey as PublicKeyCredentialRequestOptionsJSON
            });

      const verifyResponse = await fetch("/auth/passkey/verify", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          mode,
          challengeToken: options.challengeToken,
          response
        })
      });
      const verified = (await verifyResponse.json()) as VerifyResponse;
      if (!verifyResponse.ok || !verified.verified || !verified.sessionToken || !verified.userId) {
        throw new Error(verified.error || "Passkey verification failed.");
      }

      const returnURL = new URL(callback);
      returnURL.searchParams.set("sessionToken", verified.sessionToken);
      returnURL.searchParams.set("userId", verified.userId);
      returnURL.searchParams.set("serverURL", window.location.origin);
      // Echo the native-supplied state so the app can bind this callback to the
      // request it started (CSRF / replay protection).
      returnURL.searchParams.set("state", state);
      window.location.assign(returnURL.toString());
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Passkey flow failed.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <main className="aa-auth-bridge">
      <section className="aa-auth-panel">
        <div>
          <span className="aa-eyebrow">Address Atlas Mac</span>
          <h1>Passkey Sync</h1>
          <p>
            Connect the Mac app to encrypted vault sync. The server receives account auth only; vault
            contents stay encrypted before upload.
          </p>
        </div>

        {mode === "register" ? (
          <label>
            Account label
            <input
              value={accountName}
              onChange={(event) => setAccountName(event.target.value)}
              placeholder="Omer's Mac"
              maxLength={80}
              autoComplete="username webauthn"
            />
          </label>
        ) : null}

        <div className="aa-auth-actions">
          {mode ? (
            <button type="button" onClick={run} disabled={Boolean(busy) || !canReturn}>
              {busy
                ? mode === "register" ? "Creating..." : "Signing in..."
                : mode === "register" ? "Create passkey" : "Sign in"}
            </button>
          ) : null}
        </div>

        {message ? <p className="aa-auth-error">{message}</p> : null}
        {!mode ? <p className="aa-auth-error">Open this page from a valid sync action in Address Atlas Mac.</p> : null}
        {!canReturn ? <p className="aa-auth-error">Open this page from Address Atlas Mac.</p> : null}
      </section>
    </main>
  );
}
