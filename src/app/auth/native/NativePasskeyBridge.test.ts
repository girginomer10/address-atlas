import { describe, expect, it, vi } from "vitest";
import { WebAuthnError } from "@simplewebauthn/browser";
import { passkeyCeremonyUserMessage, runPasskeyCeremony } from "./NativePasskeyBridge";

const CALLBACK = "address-atlas://sync-auth";
const STATE = "11111111-1111-4111-8111-111111111111";
const ORIGIN = "https://sync.example.com";
const CODE_CHALLENGE = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const AUTHORIZATION_CODE = "v1.native-authorization.body.signature";

function jsonResponse(body: unknown, status = 200, headers: HeadersInit = {}) {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("content-type", "application/json");
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders
  });
}

function fetchStub(handlers: {
  options?: () => Response | Promise<Response>;
  verify?: () => Response | Promise<Response>;
}) {
  return vi.fn(async (input: string, init?: RequestInit) => {
    void init;
    if (input === "/auth/passkey/options" && handlers.options) return handlers.options();
    if (input === "/auth/passkey/verify" && handlers.verify) return handlers.verify();
    throw new Error(`Unexpected fetch: ${input}`);
  });
}

function sentJSON(fetchImpl: ReturnType<typeof fetchStub>, call: number) {
  return JSON.parse(fetchImpl.mock.calls[call]![1]!.body as string);
}

describe("native passkey ceremony", () => {
  it("runs the full registration ceremony and returns to the native app", async () => {
    const publicKey = { challenge: "registration-challenge", rp: { id: "localhost" } };
    const credential = { id: "credential-1", type: "public-key" };
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-1", publicKey }),
      verify: () => jsonResponse({ verified: true, authorizationCode: AUTHORIZATION_CODE })
    });
    const startRegistrationImpl = vi.fn(async () => credential);
    const startAuthenticationImpl = vi.fn(async () => ({}));
    const navigate = vi.fn();

    await runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "  Omer's Mac  ", canReturn: true },
      { fetchImpl, startRegistrationImpl, startAuthenticationImpl, locationOrigin: ORIGIN, navigate }
    );

    expect(fetchImpl).toHaveBeenNthCalledWith(1, "/auth/passkey/options", expect.objectContaining({
      method: "POST",
      headers: { "content-type": "application/json" },
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
      referrerPolicy: "no-referrer",
      signal: expect.any(AbortSignal)
    }));
    expect(sentJSON(fetchImpl, 0)).toEqual({ mode: "register", accountName: "Omer's Mac" });
    expect(startRegistrationImpl).toHaveBeenCalledExactlyOnceWith({ optionsJSON: publicKey });
    expect(startAuthenticationImpl).not.toHaveBeenCalled();
    expect(sentJSON(fetchImpl, 1)).toEqual({
      mode: "register",
      challengeToken: "challenge-token-1",
      response: credential,
      nativeCodeChallenge: CODE_CHALLENGE
    });
    expect(fetchImpl).toHaveBeenNthCalledWith(2, "/auth/passkey/verify", expect.objectContaining({
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
      referrerPolicy: "no-referrer",
      signal: expect.any(AbortSignal)
    }));

    expect(navigate).toHaveBeenCalledOnce();
    const target = new URL(navigate.mock.calls[0]![0] as string);
    expect(target.protocol).toBe("address-atlas:");
    expect(target.hostname).toBe("sync-auth");
    expect(target.searchParams.get("code")).toBe(AUTHORIZATION_CODE);
    expect(target.searchParams.has("sessionToken")).toBe(false);
    expect(target.searchParams.has("userId")).toBe(false);
    expect(target.searchParams.get("serverURL")).toBe(ORIGIN);
    expect(target.searchParams.get("state")).toBe(STATE);
  });

  it("runs the authentication ceremony without sending an account name", async () => {
    const publicKey = { challenge: "authentication-challenge", rpId: "localhost" };
    const assertion = { id: "credential-2", type: "public-key" };
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-2", publicKey }),
      verify: () => jsonResponse({ verified: true, authorizationCode: AUTHORIZATION_CODE })
    });
    const startRegistrationImpl = vi.fn(async () => ({}));
    const startAuthenticationImpl = vi.fn(async () => assertion);
    const navigate = vi.fn();

    await runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      { fetchImpl, startRegistrationImpl, startAuthenticationImpl, locationOrigin: ORIGIN, navigate }
    );

    expect(sentJSON(fetchImpl, 0)).toEqual({ mode: "authenticate" });
    expect(startAuthenticationImpl).toHaveBeenCalledExactlyOnceWith({ optionsJSON: publicKey });
    expect(startRegistrationImpl).not.toHaveBeenCalled();
    expect(sentJSON(fetchImpl, 1)).toEqual({
      mode: "authenticate",
      challengeToken: "challenge-token-2",
      response: assertion,
      nativeCodeChallenge: CODE_CHALLENGE
    });
    const target = new URL(navigate.mock.calls[0]![0] as string);
    expect(target.searchParams.get("code")).toBe(AUTHORIZATION_CODE);
    expect(target.searchParams.has("sessionToken")).toBe(false);
    expect(target.searchParams.get("serverURL")).toBe(ORIGIN);
  });

  it("refuses to start without a valid native return URL", async () => {
    const fetchImpl = fetchStub({});
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: "address-atlas://attacker", state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: false },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Open this page from Address Atlas Mac.");

    expect(fetchImpl).not.toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("uses the options response retry window in the rate-limit message", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse(
        { error: "Too many requests." },
        429,
        { "retry-after": "3600" }
      )
    });
    const startRegistrationImpl = vi.fn(async () => ({}));
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl,
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Too many passkey attempts. Try again in 1 hour.");

    expect(startRegistrationImpl).not.toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("uses Retry-After even when a rate-limit body is not readable", async () => {
    const fetchImpl = fetchStub({
      options: () => new Response("not-json", {
        status: 429,
        headers: { "retry-after": "45" }
      })
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("Too many passkey attempts. Try again in 45 seconds.");
  });

  it("keeps sync-server preparation failures separate from authenticator failures", async () => {
    const fetchImpl = fetchStub({
      options: () => {
        throw new TypeError("network unavailable");
      }
    });

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("Passkey sign-in could not be prepared. Check the sync server and try again.");
  });

  it("uses the verification response retry window without retrying early", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({
        mode: "authenticate",
        challengeToken: "challenge-token-rate-limit",
        publicKey: {}
      }),
      verify: () => jsonResponse(
        { error: "Too many requests." },
        429,
        { "retry-after": "90" }
      )
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-rate-limit" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Too many passkey attempts. Try again in 2 minutes.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("ignores an unbounded Retry-After value instead of rendering it", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse(
        { error: "Too many requests." },
        429,
        { "retry-after": "999999999999999999999" }
      )
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("Too many passkey attempts. Try again later.");
  });

  it("explains a closed registration window without rendering server text", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ error: "operator-only internal detail" }, 403)
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("New sync-account registration is currently closed.");
  });

  it("does not surface a failed verification's server-controlled message", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-3", publicKey: {} }),
      verify: () => jsonResponse({ verified: false, error: "database host: internal.example" }, 400)
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-3" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Passkey verification was rejected. No account changes were made.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("treats an ok verification without an authorization code as an unknown authentication outcome", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-4", publicKey: {} }),
      verify: () => jsonResponse({ verified: true })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-4" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Sign-in may have completed, but confirmation was lost. Try Sign in again.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("rejects truthy non-boolean verification data as an unknown outcome", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-shape", publicKey: {} }),
      verify: () => jsonResponse({
        verified: "true",
        authorizationCode: AUTHORIZATION_CODE
      })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-shape" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Sign-in may have completed, but confirmation was lost. Try Sign in again.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("refuses a malformed authorization code even after a verified response", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-callback", publicKey: {} }),
      verify: () => jsonResponse({
        verified: true,
        authorizationCode: "native-code\r\nInjected: header"
      })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({ id: "credential-callback" })),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow(
      "The server may have created this sync account and passkey, but confirmation was lost. Try Sign in before registering again."
    );

    expect(navigate).not.toHaveBeenCalled();
  });

  it("refuses an authorization code with non-token characters", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-user", publicKey: {} }),
      verify: () => jsonResponse({
        verified: true,
        authorizationCode: "native code with spaces"
      })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-user" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Sign-in may have completed, but confirmation was lost. Try Sign in again.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("maps an authenticator failure to local recovery guidance without exposing implementation details", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-5", publicKey: {} })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw new Error("The operation either timed out or was not allowed.");
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow(
      "The device could not use a passkey. Make sure Touch ID or a passkey-compatible security key is available, then try again."
    );

    expect(fetchImpl).toHaveBeenCalledExactlyOnceWith("/auth/passkey/options", expect.anything());
    expect(navigate).not.toHaveBeenCalled();
  });

  it("gives actionable guidance for an authenticator missing required passkey capabilities", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-capability", publicKey: {} })
    });
    const capabilityFailure = new WebAuthnError({
      message: "browser-controlled capability detail",
      code: "ERROR_AUTHENTICATOR_MISSING_DISCOVERABLE_CREDENTIAL_SUPPORT",
      cause: new DOMException("Discoverable credentials are unsupported.", "ConstraintError")
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw capabilityFailure;
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow(
      "This authenticator does not support the required passkey features. Use Touch ID or a passkey-compatible security key, then try again."
    );
  });

  it("directs an already-registered passkey to sign in instead", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-existing", publicKey: {} })
    });
    const existingPasskey = new WebAuthnError({
      message: "browser-controlled existing credential detail",
      code: "ERROR_AUTHENTICATOR_PREVIOUSLY_REGISTERED",
      cause: new DOMException("Credential already exists.", "InvalidStateError")
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw existingPasskey;
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow(
      "This passkey is already linked to an account. Choose Sign in, or use a different passkey to create a new account."
    );
  });

  it("maps SimpleWebAuthn's overloaded NotAllowedError to a neutral retry message", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-6", publicKey: {} })
    });
    const wrappedCancellation = new WebAuthnError({
      message: "browser-controlled cancellation detail",
      code: "ERROR_PASSTHROUGH_SEE_CAUSE_PROPERTY",
      cause: new DOMException("User dismissed the prompt.", "NotAllowedError")
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw wrappedCancellation;
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow(
      "The passkey prompt was cancelled, timed out, or unavailable. Try again."
    );
  });

  it("reserves cancellation copy for a signal-driven ceremony abort", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-abort", publicKey: {} })
    });
    const abortedCeremony = new WebAuthnError({
      message: "ceremony aborted by the application signal",
      code: "ERROR_CEREMONY_ABORTED",
      cause: new DOMException("The operation was aborted.", "AbortError")
    });

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => {
          throw abortedCeremony;
        }),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("Passkey sign-in was cancelled.");
  });

  it("does not claim registration failed when the verification response is lost", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-7", publicKey: {} }),
      verify: async () => {
        throw new TypeError("network connection reset after request upload");
      }
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({ id: "credential-7" })),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow(
      "The server may have created this sync account and passkey, but confirmation was lost. Try Sign in before registering again."
    );
  });

  it("maps a verify-time registration closure without exposing server text", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-8", publicKey: {} }),
      verify: () => jsonResponse({ error: "operator-only detail" }, 403)
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({ id: "credential-8" })),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("New sync-account registration is currently closed.");
  });

  it("treats a server failure after verification upload as an unknown outcome", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-9", publicKey: {} }),
      verify: () => jsonResponse({ error: "internal detail" }, 503)
    });

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, codeChallenge: CODE_CHALLENGE, codeChallengeMethod: "S256", accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-9" })),
        locationOrigin: ORIGIN,
        navigate: vi.fn()
      }
    )).rejects.toThrow("Sign-in may have completed, but confirmation was lost. Try Sign in again.");
  });

  it("never renders an unclassified implementation error verbatim", () => {
    expect(passkeyCeremonyUserMessage(new Error("secret internal host and stack detail")))
      .toBe("Passkey sign-in could not be completed. Close this page and restart sync from Address Atlas Mac.");
  });
});
