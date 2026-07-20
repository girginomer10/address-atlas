import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const releaseDoctor = join(repoRoot, "scripts/release-doctor.sh");

describe("release doctor invariants", () => {
  let temporaryDirectory: string;

  beforeEach(() => {
    temporaryDirectory = realpathSync(
      mkdtempSync(join(tmpdir(), "address-atlas-release-doctor-"))
    );
  });

  afterEach(() => {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  });

  it.each([["--strcit"], ["--strict", "extra"]])(
    "rejects unknown or extra arguments: %s",
    (...args) => {
      const result = spawnSync("bash", [releaseDoctor, ...args], { encoding: "utf8" });
      expect(result.status).toBe(64);
      expect(result.stderr).toContain("Usage:");
    }
  );

  it("requires the selected identity itself to be Developer ID Application", () => {
    installExecutable("swift", "exit 0");
    installExecutable("xcodebuild", "exit 0");
    installExecutable("security", `
if [ "$1" = "find-identity" ]; then
  printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Release (TEAMID)"'
  printf '%s\\n' '  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Debug (TEAMID)"'
fi
exit 0`);
    const result = runReleaseDoctor("Apple Development: Debug (TEAMID)");

    expect(result.status).toBe(1);
    expect(result.stdout).toContain("FAIL Selected signing identity is not a Developer ID Application identity");
  }, 15_000);

  it("accepts an exactly selected Developer ID Application identity", () => {
    installExecutable("swift", "exit 0");
    installExecutable("xcodebuild", "exit 0");
    installExecutable("security", `
if [ "$1" = "find-identity" ]; then
  printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Release (TEAMID)"'
fi
exit 0`);
    const result = runReleaseDoctor("Developer ID Application: Release (TEAMID)");

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("PASS Selected Developer ID Application identity exists in Keychain");
  }, 15_000);

  it("accepts the exact SHA-1 identifier of a Developer ID Application identity", () => {
    installExecutable("swift", "exit 0");
    installExecutable("xcodebuild", "exit 0");
    installExecutable("security", `
if [ "$1" = "find-identity" ]; then
  printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Release (TEAMID)"'
fi
exit 0`);
    const result = runReleaseDoctor("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("PASS Selected Developer ID Application identity exists in Keychain");
  }, 15_000);

  it("accepts exactly --strict and validates the selected notary profile", () => {
    installExecutable("swift", "exit 0");
    installExecutable("xcodebuild", "exit 0");
    installExecutable("security", `
if [ "$1" = "find-identity" ]; then
  printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Release (TEAMID)"'
fi
exit 0`);
    installExecutable("xcrun", "exit 0");
    const result = runReleaseDoctor("Developer ID Application: Release (TEAMID)", ["--strict"]);

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("PASS Selected notary profile is valid");
  }, 15_000);

  it("validates a complete private direct App Store Connect notary key", () => {
    installExecutable("swift", "exit 0");
    installExecutable("xcodebuild", "exit 0");
    installExecutable("security", `
if [ "$1" = "find-identity" ]; then
  printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Release (TEAMID)"'
fi
exit 0`);
    installExecutable("xcrun", "exit 0");
    const keyPath = join(temporaryDirectory, "AuthKey_TESTKEY123.p8");
    writeFileSync(keyPath, "TEST PRIVATE KEY MATERIAL");
    chmodSync(keyPath, 0o600);

    const result = runReleaseDoctor(
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      ["--strict"],
      {
        ADDRESS_ATLAS_NOTARY_PROFILE: "",
        ADDRESS_ATLAS_NOTARY_KEY_PATH: keyPath,
        ADDRESS_ATLAS_NOTARY_KEY_ID: "TESTKEY123",
        ADDRESS_ATLAS_NOTARY_ISSUER_ID: "12345678-1234-1234-1234-123456789abc"
      }
    );

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("PASS Direct App Store Connect notary credentials are configured privately");
    expect(result.stdout).toContain("PASS Selected direct notary credentials are valid");
  }, 15_000);

  function installExecutable(name: string, body: string) {
    const path = join(temporaryDirectory, name);
    writeFileSync(path, `#!/bin/sh\n${body}\n`);
    chmodSync(path, 0o755);
  }

  function runReleaseDoctor(
    identity: string,
    args: string[] = [],
    environment: Record<string, string> = {}
  ) {
    installExecutable("docker", `
case "$*" in
  *"config --format json"*)
    printf '%s\\n' '{"services":{"postgres":{"environment":{},"networks":{"data":null}},"web":{"environment":{}}},"networks":{"data":{"internal":true}}}'
    ;;
esac
exit 0`);
    installExecutable("curl", "exit 0");
    installExecutable("age", "exit 0");
    installExecutable("age-keygen", "exit 0");
    installExecutable("openssl", "exit 0");
    installExecutable("node", `exec "${process.execPath}" "$@"`);
    installExecutable("npm", `
if [ "$1" = "--version" ]; then
  printf '%s\\n' '10.9.2'
fi
exit 0`);
    installExecutable("git", `
if [ "$1" = "branch" ] && [ "$2" = "--show-current" ]; then
  printf '%s\\n' main
elif [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
  printf '%s\\n' 0123456789abcdef0123456789abcdef01234567
fi
exit 0`);
    const backupIdentity = join(temporaryDirectory, "backup.agekey");
    writeFileSync(backupIdentity, "AGE-SECRET-KEY-TEST-ONLY\n");
    chmodSync(backupIdentity, 0o600);
    const backupSigningPrivateKey = join(temporaryDirectory, "backup-signing-private.pem");
    const backupSigningPublicKey = join(temporaryDirectory, "backup-signing-public.pem");
    writeFileSync(backupSigningPrivateKey, "TEST SIGNING PRIVATE KEY\n");
    writeFileSync(backupSigningPublicKey, "TEST SIGNING PUBLIC KEY\n");
    chmodSync(backupSigningPrivateKey, 0o600);
    chmodSync(backupSigningPublicKey, 0o644);
    const offsiteHook = join(temporaryDirectory, "offsite-hook");
    writeFileSync(offsiteHook, "#!/bin/sh\nexit 0\n");
    chmodSync(offsiteHook, 0o700);
    const productionEnv = join(temporaryDirectory, "production.env");
    const ownerPassword = "Owner_0123456789abcdef0123456789abcdef0123456789";
    const adminPassword = "Admin_0123456789abcdef0123456789abcdef012345678";
    const runtimePassword = "Runtime_0123456789abcdef0123456789abcdef01234567";
    writeFileSync(productionEnv, [
      "ADDRESS_ATLAS_DOMAIN=sync.test.invalid",
      "ACME_EMAIL=ops@test.invalid",
      "ADDRESS_ATLAS_BACKUP_DIR=/tmp/address-atlas-release-doctor-backups",
      "ADDRESS_ATLAS_BACKUP_RETENTION_DAYS=30",
      "ADDRESS_ATLAS_BACKUP_MAX_AGE_HOURS=8",
      "ADDRESS_ATLAS_BACKUP_MAX_BYTES=53687091200",
      "ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT=age1release-doctor-test-recipient",
      `ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE=${backupIdentity}`,
      `ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE=${backupSigningPrivateKey}`,
      `ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE=${backupSigningPublicKey}`,
      "ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED=true",
      `ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK=${offsiteHook}`,
      `ADDRESS_ATLAS_NATIVE_CONFIG_STATE_FILE=${join(temporaryDirectory, "native-config-deployment.json")}`,
      "ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady",
      `POSTGRES_PASSWORD=${ownerPassword}`,
      `POSTGRES_ADMIN_PASSWORD=${adminPassword}`,
      `POSTGRES_RUNTIME_PASSWORD=${runtimePassword}`,
      `SYNC_SCHEMA_DATABASE_URL=postgresql://address_atlas:${ownerPassword}@postgres:5432/address_atlas_sync`,
      `SYNC_DATABASE_URL=postgresql://address_atlas_runtime:${runtimePassword}@postgres:5432/address_atlas_sync`,
      "SYNC_SESSION_SECRET=Session_0123456789abcdef0123456789abcdef0123456789abcdef",
      "SYNC_REGISTRATION_ENABLED=false",
      "PASSKEY_RP_ID=sync.test.invalid",
      "PASSKEY_RP_NAME=Address Atlas Test",
      ""
    ].join("\n"));
    chmodSync(productionEnv, 0o600);
    const backupScript = join(temporaryDirectory, "backup-script");
    writeFileSync(backupScript, `#!/bin/sh
case "$1" in
  latest) printf '%s\\n' /tmp/address-atlas-release-doctor.dump.age ;;
  verify|drill) exit 0 ;;
  *) exit 0 ;;
esac
`);
    chmodSync(backupScript, 0o755);
    return spawnSync("bash", [releaseDoctor, ...args], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${temporaryDirectory}:/usr/bin:/bin`,
        ADDRESS_ATLAS_PROD_ENV_FILE: productionEnv,
        ADDRESS_ATLAS_BACKUP_SCRIPT: backupScript,
        ADDRESS_ATLAS_CODESIGN_IDENTITY: identity,
        ADDRESS_ATLAS_NOTARY_PROFILE: "test-profile",
        ADDRESS_ATLAS_POSTGRES_VOLUME: "address-atlas-prod-postgres",
        ADDRESS_ATLAS_CADDY_DATA_VOLUME: "address-atlas-caddy-data",
        ADDRESS_ATLAS_CADDY_CONFIG_VOLUME: "address-atlas-caddy-config",
        ADDRESS_ATLAS_BINANCE_API_KEY: "",
        ADDRESS_ATLAS_BINANCE_SECRET: "",
        ADDRESS_ATLAS_COINBASE_API_KEY: "",
        ADDRESS_ATLAS_COINBASE_SECRET: "",
        ADDRESS_ATLAS_KRAKEN_API_KEY: "",
        ADDRESS_ATLAS_KRAKEN_SECRET: "",
        COMPOSE_PROJECT_NAME: "",
        ...environment
      }
    });
  }
});
