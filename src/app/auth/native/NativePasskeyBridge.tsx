"use client";

import { startAuthentication, startRegistration, WebAuthnError } from "@simplewebauthn/browser";
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

type PasskeyCeremonyFailureCode =
  | "invalid-return"
  | "rate-limited"
  | "registration-closed"
  | "options-unavailable"
  | "verification-rejected"
  | "registration-outcome-unknown"
  | "authentication-outcome-unknown"
  | "cancelled"
  | "authenticator-incompatible"
  | "authenticator-already-registered"
  | "authenticator-unavailable"
  | "passkey-configuration-invalid";

class PasskeyCeremonyError extends Error {
  constructor(readonly code: PasskeyCeremonyFailureCode, message = PASSKEY_FAILURE_MESSAGES[code]) {
    super(message);
    this.name = "PasskeyCeremonyError";
  }
}

const PASSKEY_FAILURE_MESSAGES: Record<PasskeyCeremonyFailureCode, string> = {
  "invalid-return": "Open this page from Address Atlas Mac.",
  "rate-limited": "Too many passkey attempts. Try again later.",
  "registration-closed": "New sync-account registration is currently closed.",
  "options-unavailable": "Passkey sign-in could not be prepared. Check the sync server and try again.",
  "verification-rejected": "Passkey verification was rejected. No account changes were made.",
  "registration-outcome-unknown":
    "The server may have created this sync account and passkey, but confirmation was lost. Try Sign in before registering again.",
  "authentication-outcome-unknown":
    "Sign-in may have completed, but confirmation was lost. Try Sign in again.",
  cancelled: "Passkey sign-in was cancelled.",
  "authenticator-incompatible":
    "This authenticator does not support the required passkey features. Use Touch ID or a passkey-compatible security key, then try again.",
  "authenticator-already-registered":
    "This passkey is already linked to an account. Choose Sign in, or use a different passkey to create a new account.",
  "authenticator-unavailable":
    "The device could not use a passkey. Make sure Touch ID or a passkey-compatible security key is available, then try again.",
  "passkey-configuration-invalid":
    "Passkey setup is unavailable for this page. Close it and restart sync from Address Atlas Mac. If the problem continues, contact support."
};
const PASSKEY_REQUEST_TIMEOUT_MS = 15_000;
const MAXIMUM_RETRY_AFTER_SECONDS = 86_400;
const UNEXPECTED_PASSKEY_FAILURE_MESSAGE =
  "Passkey sign-in could not be completed. Close this page and restart sync from Address Atlas Mac.";
const USER_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const INVALID_SESSION_TOKEN_CHARACTER_RE = /[^A-Za-z0-9._+/=~-]/;
const MAXIMUM_SESSION_TOKEN_LENGTH = 4_096;

function passkeyFailure(code: PasskeyCeremonyFailureCode): PasskeyCeremonyError {
  return new PasskeyCeremonyError(code);
}

function unknownVerificationOutcome(mode: Mode): PasskeyCeremonyError {
  return passkeyFailure(
    mode === "register" ? "registration-outcome-unknown" : "authentication-outcome-unknown"
  );
}

function retryAfterSeconds(response: Response): number | null {
  const value = response.headers.get("retry-after")?.trim();
  if (!value || !/^\d+$/.test(value)) return null;
  const seconds = Number(value);
  if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > MAXIMUM_RETRY_AFTER_SECONDS) {
    return null;
  }
  return seconds;
}

function retryDelayLabel(seconds: number): string {
  if (seconds < 60) return `${seconds} ${seconds === 1 ? "second" : "seconds"}`;
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `${minutes} ${minutes === 1 ? "minute" : "minutes"}`;
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  const hourLabel = `${hours} ${hours === 1 ? "hour" : "hours"}`;
  if (remainingMinutes === 0) return hourLabel;
  return `${hourLabel} and ${remainingMinutes} ${remainingMinutes === 1 ? "minute" : "minutes"}`;
}

function rateLimitedFailure(response: Response): PasskeyCeremonyError {
  const seconds = retryAfterSeconds(response);
  return new PasskeyCeremonyError(
    "rate-limited",
    seconds === null
      ? PASSKEY_FAILURE_MESSAGES["rate-limited"]
      : `Too many passkey attempts. Try again in ${retryDelayLabel(seconds)}.`
  );
}

function authenticatorFailure(error: unknown): PasskeyCeremonyError {
  if (
    (error instanceof WebAuthnError
      && (error.code === "ERROR_CEREMONY_ABORTED" || error.name === "NotAllowedError"))
    || (error instanceof DOMException && ["AbortError", "NotAllowedError"].includes(error.name))
  ) {
    return passkeyFailure("cancelled");
  }

  if (error instanceof WebAuthnError) {
    switch (error.code) {
      case "ERROR_AUTHENTICATOR_MISSING_DISCOVERABLE_CREDENTIAL_SUPPORT":
      case "ERROR_AUTHENTICATOR_MISSING_USER_VERIFICATION_SUPPORT":
      case "ERROR_AUTHENTICATOR_NO_SUPPORTED_PUBKEYCREDPARAMS_ALG":
      case "ERROR_AUTO_REGISTER_USER_VERIFICATION_FAILURE":
        return passkeyFailure("authenticator-incompatible");
      case "ERROR_AUTHENTICATOR_PREVIOUSLY_REGISTERED":
        return passkeyFailure("authenticator-already-registered");
      case "ERROR_INVALID_DOMAIN":
      case "ERROR_INVALID_RP_ID":
      case "ERROR_INVALID_USER_ID_LENGTH":
      case "ERROR_MALFORMED_PUBKEYCREDPARAMS":
        return passkeyFailure("passkey-configuration-invalid");
      case "ERROR_AUTHENTICATOR_GENERAL_ERROR":
      case "ERROR_PASSTHROUGH_SEE_CAUSE_PROPERTY":
      case "ERROR_CEREMONY_ABORTED":
        return passkeyFailure("authenticator-unavailable");
    }
  }

  if (error instanceof DOMException) {
    if (["ConstraintError", "NotSupportedError"].includes(error.name)) {
      return passkeyFailure("authenticator-incompatible");
    }
    if (error.name === "InvalidStateError") {
      return passkeyFailure("authenticator-already-registered");
    }
    if (error.name === "SecurityError") {
      return passkeyFailure("passkey-configuration-invalid");
    }
  }
  if (error instanceof TypeError) return passkeyFailure("passkey-configuration-invalid");
  return passkeyFailure("authenticator-unavailable");
}

function isVerifiedSession(
  response: VerifyResponse
): response is VerifyResponse & { verified: true; userId: string; sessionToken: string } {
  return response.verified === true
    && typeof response.userId === "string"
    && response.userId.length === 36
    && USER_ID_RE.test(response.userId)
    && typeof response.sessionToken === "string"
    && response.sessionToken.length > 0
    && response.sessionToken.length <= MAXIMUM_SESSION_TOKEN_LENGTH
    && !INVALID_SESSION_TOKEN_CHARACTER_RE.test(response.sessionToken);
}

export function passkeyCeremonyUserMessage(error: unknown): string {
  if (error instanceof PasskeyCeremonyError) return error.message;
  return UNEXPECTED_PASSKEY_FAILURE_MESSAGE;
}

export interface PasskeyCeremonyInput {
  mode: Mode;
  callback: string;
  state: string;
  accountName: string;
  canReturn: boolean;
}

// Injectable seams for the browser-only pieces of the ceremony so the flow is
// testable in a plain node environment. Production uses the defaults below.
export interface PasskeyCeremonyDeps {
  fetchImpl: (input: string, init?: RequestInit) => Promise<Response>;
  startRegistrationImpl: (options: {
    optionsJSON: PublicKeyCredentialCreationOptionsJSON;
  }) => Promise<unknown>;
  startAuthenticationImpl: (options: {
    optionsJSON: PublicKeyCredentialRequestOptionsJSON;
  }) => Promise<unknown>;
  locationOrigin: string;
  navigate: (url: string) => void;
}

function browserPasskeyCeremonyDeps(): PasskeyCeremonyDeps {
  return {
    fetchImpl: (input, init) => fetch(input, init),
    startRegistrationImpl: startRegistration,
    startAuthenticationImpl: startAuthentication,
    locationOrigin: window.location.origin,
    navigate: (url) => window.location.assign(url)
  };
}

export async function runPasskeyCeremony(
  { mode, callback, state, accountName, canReturn }: PasskeyCeremonyInput,
  deps: PasskeyCeremonyDeps = browserPasskeyCeremonyDeps()
): Promise<void> {
  if (!canReturn) {
    throw passkeyFailure("invalid-return");
  }
  let optionsResponse: Response;
  let options: OptionsResponse;
  try {
    optionsResponse = await deps.fetchImpl("/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
      referrerPolicy: "no-referrer",
      signal: AbortSignal.timeout(PASSKEY_REQUEST_TIMEOUT_MS),
      body: JSON.stringify({
        mode,
        accountName: accountName.trim() || undefined
      })
    });
  } catch {
    throw passkeyFailure("options-unavailable");
  }
  if (optionsResponse.status === 429) throw rateLimitedFailure(optionsResponse);
  try {
    options = (await optionsResponse.json()) as OptionsResponse;
  } catch {
    throw passkeyFailure("options-unavailable");
  }
  if (!optionsResponse.ok || options.error) {
    if (mode === "register" && optionsResponse.status === 403) {
      throw passkeyFailure("registration-closed");
    }
    throw passkeyFailure("options-unavailable");
  }
  if (options.mode !== mode || !options.challengeToken || !options.publicKey) {
    throw passkeyFailure("options-unavailable");
  }

  let response: unknown;
  try {
    response =
      mode === "register"
        ? await deps.startRegistrationImpl({
            optionsJSON: options.publicKey as PublicKeyCredentialCreationOptionsJSON
          })
        : await deps.startAuthenticationImpl({
            optionsJSON: options.publicKey as PublicKeyCredentialRequestOptionsJSON
          });
  } catch (error) {
    throw authenticatorFailure(error);
  }

  let verifyResponse: Response;
  try {
    verifyResponse = await deps.fetchImpl("/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
      referrerPolicy: "no-referrer",
      signal: AbortSignal.timeout(PASSKEY_REQUEST_TIMEOUT_MS),
      body: JSON.stringify({
        mode,
        challengeToken: options.challengeToken,
        response
      })
    });
  } catch {
    throw unknownVerificationOutcome(mode);
  }

  if (verifyResponse.status === 429) throw rateLimitedFailure(verifyResponse);
  if (mode === "register" && verifyResponse.status === 403) {
    throw passkeyFailure("registration-closed");
  }
  if (!verifyResponse.ok) {
    if (verifyResponse.status >= 400 && verifyResponse.status < 500) {
      throw passkeyFailure("verification-rejected");
    }
    throw unknownVerificationOutcome(mode);
  }

  let verified: VerifyResponse;
  try {
    verified = (await verifyResponse.json()) as VerifyResponse;
  } catch {
    throw unknownVerificationOutcome(mode);
  }
  if (verified.verified === false) {
    throw passkeyFailure("verification-rejected");
  }
  if (!isVerifiedSession(verified)) {
    throw unknownVerificationOutcome(mode);
  }

  const returnURL = new URL(callback);
  returnURL.searchParams.set("sessionToken", verified.sessionToken);
  returnURL.searchParams.set("userId", verified.userId);
  returnURL.searchParams.set("serverURL", deps.locationOrigin);
  // Echo the native-supplied state so the app can bind this callback to the
  // request it started (CSRF / replay protection).
  returnURL.searchParams.set("state", state);
  deps.navigate(returnURL.toString());
}

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
        && !url.username
        && !url.password
        && !url.port
        && !url.pathname
        && !url.search
        && !url.hash
        && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(state);
    } catch {
      return false;
    }
  }, [callback, state]);
  const validationMessage = !mode
    ? "Open this page from a valid sync action in Address Atlas Mac."
    : !canReturn
      ? "Open this page from Address Atlas Mac."
      : "";
  const statusMessage = message || validationMessage;

  async function run() {
    if (!mode) {
      setMessage("A valid passkey action is required.");
      return;
    }
    setBusy(mode);
    setMessage("");
    try {
      await runPasskeyCeremony({ mode, callback, state, accountName, canReturn });
    } catch (error) {
      setMessage(passkeyCeremonyUserMessage(error));
    } finally {
      setBusy(null);
    }
  }

  return (
    <main className="aa-auth-bridge">
      <div
        className="aa-auth-panel"
        aria-busy={Boolean(busy)}
        aria-describedby={statusMessage ? "passkey-status" : undefined}
        aria-labelledby="passkey-heading"
      >
        <div>
          <span className="aa-eyebrow">Address Atlas Mac</span>
          <h1 id="passkey-heading">Passkey Sync</h1>
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
              onKeyDown={(event) => {
                if (event.key !== "Enter") return;
                event.preventDefault();
                if (!busy && canReturn) void run();
              }}
            />
          </label>
        ) : null}

        <div className="aa-auth-actions">
          {mode ? (
            <button
              type="button"
              disabled={Boolean(busy) || !canReturn}
              onClick={() => {
                if (!busy) void run();
              }}
            >
              {busy
                ? mode === "register" ? "Creating..." : "Signing in..."
                : mode === "register" ? "Create passkey" : "Sign in"}
            </button>
          ) : null}
        </div>

        {statusMessage ? (
          <p
            id="passkey-status"
            className="aa-auth-error"
            role="alert"
            aria-live="assertive"
            aria-atomic="true"
          >
            {statusMessage}
          </p>
        ) : null}
      </div>
    </main>
  );
}
