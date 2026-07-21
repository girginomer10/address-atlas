import { describe, expect, it, vi } from "vitest";
import { WebAuthnError } from "@simplewebauthn/browser";
import { passkeyCeremonyUserMessage, runPasskeyCeremony } from "./NativePasskeyBridge";

const CALLBACK = "address-atlas://sync-auth";
const STATE = "11111111-1111-4111-8111-111111111111";
const ORIGIN = "https://sync.example.com";
const USER_ID = "22222222-2222-4222-8222-222222222222";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
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
      verify: () => jsonResponse({ verified: true, userId: USER_ID, sessionToken: "session-token-1" })
    });
    const startRegistrationImpl = vi.fn(async () => credential);
    const startAuthenticationImpl = vi.fn(async () => ({}));
    const navigate = vi.fn();

    await runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "  Omer's Mac  ", canReturn: true },
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
      response: credential
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
    expect(target.searchParams.get("sessionToken")).toBe("session-token-1");
    expect(target.searchParams.get("userId")).toBe(USER_ID);
    expect(target.searchParams.get("serverURL")).toBe(ORIGIN);
    expect(target.searchParams.get("state")).toBe(STATE);
  });

  it("runs the authentication ceremony without sending an account name", async () => {
    const publicKey = { challenge: "authentication-challenge", rpId: "localhost" };
    const assertion = { id: "credential-2", type: "public-key" };
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-2", publicKey }),
      verify: () => jsonResponse({ verified: true, userId: USER_ID, sessionToken: "session-token-2" })
    });
    const startRegistrationImpl = vi.fn(async () => ({}));
    const startAuthenticationImpl = vi.fn(async () => assertion);
    const navigate = vi.fn();

    await runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      { fetchImpl, startRegistrationImpl, startAuthenticationImpl, locationOrigin: ORIGIN, navigate }
    );

    expect(sentJSON(fetchImpl, 0)).toEqual({ mode: "authenticate" });
    expect(startAuthenticationImpl).toHaveBeenCalledExactlyOnceWith({ optionsJSON: publicKey });
    expect(startRegistrationImpl).not.toHaveBeenCalled();
    expect(sentJSON(fetchImpl, 1)).toEqual({
      mode: "authenticate",
      challengeToken: "challenge-token-2",
      response: assertion
    });
    const target = new URL(navigate.mock.calls[0]![0] as string);
    expect(target.searchParams.get("sessionToken")).toBe("session-token-2");
    expect(target.searchParams.get("serverURL")).toBe(ORIGIN);
  });

  it("refuses to start without a valid native return URL", async () => {
    const fetchImpl = fetchStub({});
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: "address-atlas://attacker", state: STATE, accountName: "", canReturn: false },
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

  it("maps a failed options request to a reviewed rate-limit message", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ error: "Too many requests." }, 429)
    });
    const startRegistrationImpl = vi.fn(async () => ({}));
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl,
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Too many passkey attempts. Wait a moment, then try again.");

    expect(startRegistrationImpl).not.toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("explains a closed registration window without rendering server text", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ error: "operator-only internal detail" }, 403)
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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

  it("treats an ok verification without a session token as an unknown authentication outcome", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-4", publicKey: {} }),
      verify: () => jsonResponse({ verified: true, userId: USER_ID })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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
        userId: USER_ID,
        sessionToken: "session-token-shaped"
      })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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

  it("refuses malformed callback credentials even after a verified response", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-callback", publicKey: {} }),
      verify: () => jsonResponse({
        verified: true,
        userId: USER_ID,
        sessionToken: "session-token\r\nInjected: header"
      })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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

  it("refuses a malformed verified user identity", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-user", publicKey: {} }),
      verify: () => jsonResponse({
        verified: true,
        userId: "not-a-user-id",
        sessionToken: "v1.session.body.signature"
      })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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

  it("maps an authenticator failure without exposing its implementation message", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-5", publicKey: {} })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw new Error("The operation either timed out or was not allowed.");
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Passkey sign-in could not be completed. Check the sync server and try again.");

    expect(fetchImpl).toHaveBeenCalledExactlyOnceWith("/auth/passkey/options", expect.anything());
    expect(navigate).not.toHaveBeenCalled();
  });

  it("maps SimpleWebAuthn's wrapped NotAllowedError to a neutral cancellation", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-6", publicKey: {} })
    });
    const wrappedCancellation = new WebAuthnError({
      message: "browser-controlled cancellation detail",
      code: "ERROR_PASSTHROUGH_SEE_CAUSE_PROPERTY",
      cause: new DOMException("User dismissed the prompt.", "NotAllowedError")
    });

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw wrappedCancellation;
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
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
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
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
      .toBe("Passkey sign-in could not be completed. Check the sync server and try again.");
  });
});
