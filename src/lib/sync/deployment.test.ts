import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const manageScript = join(repoRoot, "server/sync/manage-prod.sh");
const composeFile = join(repoRoot, "server/sync/compose.prod.yml");
const productionEnvExample = join(repoRoot, "server/sync/.env.production.example");
const syncReadme = join(repoRoot, "server/sync/README.md");
const developmentEnvExample = join(repoRoot, ".env.example");
const globalStyles = join(repoRoot, "src/app/globals.css");
const caddyFile = join(repoRoot, "server/sync/Caddyfile");
const releaseDoctor = join(repoRoot, "scripts/release-doctor.sh");
const releaseChecklist = join(repoRoot, "docs/RELEASE_CHECKLIST.md");

describe("production sync deployment invariants", () => {
  let temporaryDirectory: string;
  let fakeDocker: string;
  let hermeticEnvFile: string;

  beforeEach(() => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "address-atlas-deploy-"));
    hermeticEnvFile = join(temporaryDirectory, "production.env");
    writeFileSync(hermeticEnvFile, "");
    fakeDocker = join(temporaryDirectory, "docker");
    writeFileSync(fakeDocker, `#!/bin/sh
if [ -n "\${FAKE_DOCKER_LOG:-}" ]; then
  printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
fi
if [ "$1" = "volume" ] && [ "$2" = "ls" ]; then
  [ "\${FAKE_DOCKER_LS_FAIL:-0}" = "1" ] && exit 72
  volume_filter=""
  project_filter=""
  for argument in "$@"; do
    case "$argument" in
      label=com.docker.compose.volume=*) volume_filter="$argument" ;;
      label=com.docker.compose.project=*) project_filter="$argument" ;;
    esac
  done
  case "$project_filter" in
    *address-atlas-sync|*address-atlas) scoped=true ;;
    *) scoped=false ;;
  esac
  case "$volume_filter" in
    *address-atlas-prod-postgres)
      if [ "$scoped" = true ]; then printf '%s\\n' "\${FAKE_DOCKER_POSTGRES_VOLUMES:-}";
      else printf '%s\\n' "\${FAKE_DOCKER_UNSCOPED_POSTGRES_VOLUMES:-}"; fi ;;
    *caddy-data)
      if [ "$scoped" = true ]; then printf '%s\\n' "\${FAKE_DOCKER_CADDY_DATA_VOLUMES:-}";
      else printf '%s\\n' "\${FAKE_DOCKER_UNSCOPED_CADDY_DATA_VOLUMES:-}"; fi ;;
    *caddy-config)
      if [ "$scoped" = true ]; then printf '%s\\n' "\${FAKE_DOCKER_CADDY_CONFIG_VOLUMES:-}";
      else printf '%s\\n' "\${FAKE_DOCKER_UNSCOPED_CADDY_CONFIG_VOLUMES:-}"; fi ;;
    *) exit 71 ;;
  esac
  exit 0
fi
if [ "$1" = "volume" ] && [ "$2" = "inspect" ]; then
  printf '%s\\n' "\${FAKE_DOCKER_ALL_VOLUMES:-}" | grep -Fqx "$3"
  exit $?
fi
if [ "$1" = "ps" ]; then
  [ "\${FAKE_DOCKER_PS_FAIL:-0}" = "1" ] && exit 73
  selected_volume=""
  for argument in "$@"; do
    case "$argument" in volume=*) selected_volume="\${argument#volume=}" ;; esac
  done
  case "$selected_volume" in
    address-atlas-prod-postgres|address-atlas_address-atlas-prod-postgres|address-atlas-sync_address-atlas-prod-postgres)
      printf '%s\\n' "\${FAKE_DOCKER_RUNNING_POSTGRES:-}" ;;
    address-atlas-caddy-data|address-atlas_caddy-data|address-atlas-sync_caddy-data)
      printf '%s\\n' "\${FAKE_DOCKER_RUNNING_CADDY_DATA:-}" ;;
    address-atlas-caddy-config|address-atlas_caddy-config|address-atlas-sync_caddy-config)
      printf '%s\\n' "\${FAKE_DOCKER_RUNNING_CADDY_CONFIG:-}" ;;
  esac
  exit 0
fi
if [ "$1" = "compose" ]; then
  if [ -n "\${FAKE_DOCKER_COMPOSE_ENV:-}" ]; then
    printf '%s|%s|%s\\n' "$ADDRESS_ATLAS_POSTGRES_VOLUME" "$ADDRESS_ATLAS_CADDY_DATA_VOLUME" "$ADDRESS_ATLAS_CADDY_CONFIG_VOLUME" > "$FAKE_DOCKER_COMPOSE_ENV"
  fi
  exit 0
fi
exit 70
`);
    chmodSync(fakeDocker, 0o755);
  });

  afterEach(() => {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  });

  it("uses a stable explicit volume for a first installation", () => {
    expect(detectVolume()).toBe("address-atlas-prod-postgres");
  });

  it("rejects missing, unknown, or extra wrapper arguments", () => {
    for (const args of [[], ["unknown"], ["up", "--remove-orphans"]]) {
      const result = spawnSync("bash", [manageScript, ...args], {
        encoding: "utf8",
        env: baseEnvironment()
      });
      expect(result.status).toBe(64);
      expect(result.stderr).toContain("Usage:");
    }
  });

  it.each([
    "address-atlas_address-atlas-prod-postgres",
    "address-atlas-sync_address-atlas-prod-postgres"
  ])("reconnects the historical Compose volume %s", (volume) => {
    expect(detectVolume({
      FAKE_DOCKER_POSTGRES_VOLUMES: volume,
      FAKE_DOCKER_ALL_VOLUMES: volume
    })).toBe(volume);
  });

  it("fails closed when multiple historical volumes exist", () => {
    const result = spawnSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: join(temporaryDirectory, "missing.env"),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "",
        FAKE_DOCKER_POSTGRES_VOLUMES: [
          "address-atlas_address-atlas-prod-postgres",
          "address-atlas-sync_address-atlas-prod-postgres"
        ].join("\n"),
        FAKE_DOCKER_ALL_VOLUMES: [
          "address-atlas_address-atlas-prod-postgres",
          "address-atlas-sync_address-atlas-prod-postgres"
        ].join("\n")
      }
    });

    expect(result.status).toBe(66);
    expect(result.stderr).toContain("Multiple Address Atlas PostgreSQL data volumes");
    expect(result.stderr).toContain("ADDRESS_ATLAS_POSTGRES_VOLUME");
  });

  it("honors an explicit operator choice when discovery is ambiguous", () => {
    expect(detectVolume({
      ADDRESS_ATLAS_POSTGRES_VOLUME: "chosen-address-atlas-volume",
      FAKE_DOCKER_POSTGRES_VOLUMES: [
        "chosen-address-atlas-volume",
        "address-atlas_address-atlas-prod-postgres",
        "address-atlas-sync_address-atlas-prod-postgres"
      ].join("\n"),
      FAKE_DOCKER_ALL_VOLUMES: [
        "chosen-address-atlas-volume",
        "address-atlas_address-atlas-prod-postgres",
        "address-atlas-sync_address-atlas-prod-postgres"
      ].join("\n")
    })).toBe("chosen-address-atlas-volume");
  });

  it("refuses to create a configured empty volume over discovered legacy data", () => {
    const result = spawnSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: join(temporaryDirectory, "missing.env"),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "address-atlas-prod-postgres",
        FAKE_DOCKER_POSTGRES_VOLUMES: "address-atlas_address-atlas-prod-postgres",
        FAKE_DOCKER_ALL_VOLUMES: "address-atlas_address-atlas-prod-postgres"
      }
    });

    expect(result.status).toBe(66);
    expect(result.stderr).toContain("does not exist");
    expect(result.stderr).toContain("Refusing to attach a new empty volume");
  });

  it("fails closed when Docker volume discovery itself is unavailable", () => {
    const result = spawnSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: join(temporaryDirectory, "missing.env"),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "",
        FAKE_DOCKER_LS_FAIL: "1"
      }
    });

    expect(result.status).toBe(69);
    expect(result.stderr).toContain("refusing to guess");
  });

  it("reconnects historical Caddy account, certificate, and config state", () => {
    const postgres = "address-atlas_address-atlas-prod-postgres";
    const caddyData = "address-atlas_caddy-data";
    const caddyConfig = "address-atlas_caddy-config";
    const output = execFileSync("bash", [manageScript, "detect-volumes"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: join(temporaryDirectory, "missing.env"),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "",
        ADDRESS_ATLAS_CADDY_DATA_VOLUME: "",
        ADDRESS_ATLAS_CADDY_CONFIG_VOLUME: "",
        FAKE_DOCKER_POSTGRES_VOLUMES: postgres,
        FAKE_DOCKER_CADDY_DATA_VOLUMES: caddyData,
        FAKE_DOCKER_CADDY_CONFIG_VOLUMES: caddyConfig,
        FAKE_DOCKER_ALL_VOLUMES: [postgres, caddyData, caddyConfig].join("\n")
      }
    });

    expect(output).toContain(`PostgreSQL data: ${postgres}`);
    expect(output).toContain(`Caddy data: ${caddyData}`);
    expect(output).toContain(`Caddy config: ${caddyConfig}`);
  });

  it.each([
    ["one", ["other-stack_caddy-data"]],
    ["multiple", ["other-stack_caddy-data", "custom-project_caddy-data"]]
  ])("fails closed when %s unrecognized project volume carries the same logical label", (_count, foreignVolumes) => {
    const logFile = join(temporaryDirectory, "docker.log");
    const result = spawnSync("bash", [manageScript, "detect-volumes"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: logFile,
        FAKE_DOCKER_UNSCOPED_CADDY_DATA_VOLUMES: foreignVolumes.join("\n"),
        FAKE_DOCKER_ALL_VOLUMES: foreignVolumes.join("\n")
      }
    });

    expect(result.status).toBe(66);
    expect(result.stderr).toContain("outside recognized Address Atlas projects");
    expect(result.stderr).toContain("ADDRESS_ATLAS_CADDY_DATA_VOLUME");
    expect(result.stderr).toContain("refusing to create or adopt");
    for (const volume of foreignVolumes) {
      expect(result.stderr).toContain(volume);
    }
    const invocations = readFileSync(logFile, "utf8").split("\n").filter(Boolean);
    expect(invocations.some((line) => line === "volume ls --filter label=com.docker.compose.volume=caddy-data --format {{.Name}}"))
      .toBe(true);
    expect(invocations.some((line) => line.startsWith("compose "))).toBe(false);
  });

  it("honors an explicit authoritative custom-project volume without auto-adopting it", () => {
    const customVolume = "custom-project_address-atlas-prod-postgres";
    expect(detectVolume({
      ADDRESS_ATLAS_POSTGRES_VOLUME: customVolume,
      FAKE_DOCKER_UNSCOPED_POSTGRES_VOLUMES: customVolume,
      FAKE_DOCKER_ALL_VOLUMES: customVolume
    })).toBe(customVolume);
  });

  it("refuses a nonexistent typo override when custom-project state may exist", () => {
    const customVolume = "custom-project_address-atlas-prod-postgres";
    const result = spawnSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "typo-new-postgres-volume",
        FAKE_DOCKER_UNSCOPED_POSTGRES_VOLUMES: customVolume,
        FAKE_DOCKER_ALL_VOLUMES: customVolume
      }
    });

    expect(result.status).toBe(66);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain(customVolume);
    expect(result.stderr).toContain("ADDRESS_ATLAS_POSTGRES_VOLUME");
    expect(result.stderr).toContain("address-atlas-prod-postgres");
  });

  it("refuses to create a nonexistent arbitrary override even without discoverable state", () => {
    const result = spawnSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "typo-new-postgres-volume"
      }
    });

    expect(result.status).toBe(66);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("does not exist");
    expect(result.stderr).toContain("may be a typo");
    expect(result.stderr).toContain("address-atlas-prod-postgres");
  });

  it("allows an explicit stable-name acknowledgement for a confirmed clean installation", () => {
    const output = execFileSync("bash", [manageScript, "detect-volumes"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_POSTGRES_VOLUME: "address-atlas-prod-postgres",
        ADDRESS_ATLAS_CADDY_DATA_VOLUME: "address-atlas-caddy-data",
        ADDRESS_ATLAS_CADDY_CONFIG_VOLUME: "address-atlas-caddy-config",
        FAKE_DOCKER_UNSCOPED_CADDY_DATA_VOLUMES: "other-stack_caddy-data",
        FAKE_DOCKER_UNSCOPED_CADDY_CONFIG_VOLUMES: "other-stack_caddy-config",
        FAKE_DOCKER_ALL_VOLUMES: ["other-stack_caddy-data", "other-stack_caddy-config"].join("\n")
      }
    });

    expect(output).toContain("PostgreSQL data: address-atlas-prod-postgres");
    expect(output).toContain("Caddy data: address-atlas-caddy-data");
    expect(output).toContain("Caddy config: address-atlas-caddy-config");
  });

  it("validates Compose through the same non-mutating volume preflight", () => {
    const logFile = join(temporaryDirectory, "docker.log");
    const composeEnvironment = join(temporaryDirectory, "compose-env.txt");
    execFileSync("bash", [manageScript, "config"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: logFile,
        FAKE_DOCKER_COMPOSE_ENV: composeEnvironment
      }
    });

    expect(readFileSync(composeEnvironment, "utf8").trim()).toBe([
      "address-atlas-prod-postgres",
      "address-atlas-caddy-data",
      "address-atlas-caddy-config"
    ].join("|"));
    const composeCall = readFileSync(logFile, "utf8")
      .split("\n")
      .find((line) => line.startsWith("compose "));
    expect(composeCall).toContain(`-f ${composeFile} config --quiet`);
    expect(composeCall).toContain("--project-name address-atlas-sync");
    expect(composeCall).not.toContain(" up ");
  });

  it("rejects an explicitly selected missing production environment file", () => {
    const missingEnvFile = join(temporaryDirectory, "missing.env");
    const result = spawnSync("bash", [manageScript, "config"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: missingEnvFile
      }
    });

    expect(result.status).toBe(66);
    expect(result.stderr).toContain(`Missing production environment file: ${missingEnvFile}`);
  });

  it("refuses to start while a legacy project mounts the selected Postgres volume", () => {
    const envFile = join(temporaryDirectory, "production.env");
    writeFileSync(envFile, "");
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: envFile,
        FAKE_DOCKER_ALL_VOLUMES: [
          "address-atlas-prod-postgres",
          "address-atlas-caddy-data",
          "address-atlas-caddy-config"
        ].join("\n"),
        FAKE_DOCKER_RUNNING_POSTGRES: "legacy123|address-atlas|postgres"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("refusing simultaneous volume attachment");
    expect(result.stderr).toContain("address-atlas");
  });

  it.each([
    ["foreign Postgres", "FAKE_DOCKER_RUNNING_POSTGRES", "postgres123|foreign-project|postgres"],
    ["unlabeled Postgres", "FAKE_DOCKER_RUNNING_POSTGRES", "postgres123||"],
    ["wrong-service Postgres", "FAKE_DOCKER_RUNNING_POSTGRES", "postgres123|address-atlas-sync|web"],
    ["foreign Caddy data", "FAKE_DOCKER_RUNNING_CADDY_DATA", "caddy123|foreign-project|caddy"],
    ["unlabeled Caddy config", "FAKE_DOCKER_RUNNING_CADDY_CONFIG", "caddy123||"],
    ["wrong-service Caddy config", "FAKE_DOCKER_RUNNING_CADDY_CONFIG", "caddy123|address-atlas-sync|web"]
  ] as const)("rejects a %s volume mount", (_description, variableName, runningContainer) => {
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        [variableName]: runningContainer
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("refusing simultaneous volume attachment");
    if (runningContainer.includes("||")) {
      expect(result.stderr).toContain("<unlabeled>");
    } else if (runningContainer.includes("foreign-project")) {
      expect(result.stderr).toContain("foreign-project");
    } else {
      expect(result.stderr).toContain("service 'web'");
    }
  });

  it("fails closed when running-container inspection fails", () => {
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_PS_FAIL: "1"
      }
    });

    expect(result.status).toBe(69);
    expect(result.stderr).toContain("Unable to inspect running containers");
    expect(result.stderr).toContain("refusing to start");
  });

  it("pins the project name and permits only the expected current service mounts", () => {
    const envFile = join(temporaryDirectory, "production.env");
    const logFile = join(temporaryDirectory, "docker.log");
    writeFileSync(envFile, "COMPOSE_PROJECT_NAME=foreign-project\n");

    execFileSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: envFile,
        COMPOSE_PROJECT_NAME: "also-foreign",
        FAKE_DOCKER_LOG: logFile,
        FAKE_DOCKER_ALL_VOLUMES: [
          "address-atlas-prod-postgres",
          "address-atlas-caddy-data",
          "address-atlas-caddy-config"
        ].join("\n"),
        FAKE_DOCKER_RUNNING_POSTGRES: "postgres123|address-atlas-sync|postgres",
        FAKE_DOCKER_RUNNING_CADDY_DATA: "caddy123|address-atlas-sync|caddy",
        FAKE_DOCKER_RUNNING_CADDY_CONFIG: "caddy123|address-atlas-sync|caddy"
      }
    });

    const composeCall = readFileSync(logFile, "utf8")
      .split("\n")
      .find((line) => line.startsWith("compose "));
    expect(composeCall).toContain("--project-name address-atlas-sync");
    expect(composeCall).toContain(" up -d --build");
  });

  it("derives WebAuthn origin from the published host and forwards database controls", () => {
    const compose = readFileSync(composeFile, "utf8");
    const envExample = readFileSync(productionEnvExample, "utf8");
    const developmentEnv = readFileSync(developmentEnvExample, "utf8");

    expect(compose).toContain('PASSKEY_ORIGIN: "https://\${ADDRESS_ATLAS_DOMAIN:');
    expect(compose).toContain('ADDRESS_ATLAS_DOMAIN: "\${ADDRESS_ATLAS_DOMAIN:');
    expect(compose).toContain('name: "\${ADDRESS_ATLAS_POSTGRES_VOLUME:-address-atlas-prod-postgres}"');
    expect(compose).toContain('name: "\${ADDRESS_ATLAS_CADDY_DATA_VOLUME:-address-atlas-caddy-data}"');
    expect(compose).toContain('name: "\${ADDRESS_ATLAS_CADDY_CONFIG_VOLUME:-address-atlas-caddy-config}"');
    expect(compose).toContain('NATIVE_ENDPOINT_CONFIG_VERSION: "\${NATIVE_ENDPOINT_CONFIG_VERSION:-5}"');
    expect(compose).toContain('NATIVE_ENDPOINT_CONFIG_UPDATED_AT: "\${NATIVE_ENDPOINT_CONFIG_UPDATED_AT:-2026-07-14T00:00:00.000Z}"');
    for (const setting of ["SYNC_DB_POOL_SIZE", "SYNC_DB_IDLE_TIMEOUT_MS"]) {
      expect(compose).toContain(`${setting}:`);
      expect(envExample).toMatch(new RegExp(`^${setting}=`, "m"));
      expect(developmentEnv).toMatch(new RegExp(`^${setting}=`, "m"));
    }
    expect(envExample).not.toMatch(/^PASSKEY_ORIGIN=/m);
    for (const volumeOverride of [
      "ADDRESS_ATLAS_POSTGRES_VOLUME",
      "ADDRESS_ATLAS_CADDY_DATA_VOLUME",
      "ADDRESS_ATLAS_CADDY_CONFIG_VOLUME"
    ]) {
      expect(envExample).not.toMatch(new RegExp(`^${volumeOverride}=`, "m"));
      expect(envExample).toMatch(new RegExp(`^# ${volumeOverride}=`, "m"));
    }
  });

  it("keeps copyable Ethereum endpoint examples on PublicNode's live root path", () => {
    for (const file of [productionEnvExample, syncReadme]) {
      const contents = readFileSync(file, "utf8");
      expect(contents).toContain("https://ethereum-rpc.publicnode.com");
      expect(contents).not.toContain("https://ethereum-rpc.publicnode.com/rpc");
    }
  });

  it("documents every required native sync route", () => {
    const contents = readFileSync(syncReadme, "utf8");
    for (const route of [
      "GET /config/native",
      "GET /healthz",
      "GET /auth/native",
      "POST /auth/passkey/options",
      "POST /auth/passkey/verify",
      "GET /vault/latest",
      "PUT /vault/latest"
    ]) {
      expect(contents).toContain(`\`${route}\``);
    }
  });

  it("uses the repository-root native test command in the release checklist", () => {
    const contents = readFileSync(releaseChecklist, "utf8");

    expect(contents).toContain("Run `npm run native:test` from the repository root.");
    expect(contents).not.toContain("- Run `swift test`.");
  });

  it("uses only local system font stacks", () => {
    const styles = readFileSync(globalStyles, "utf8");

    expect(styles).not.toMatch(/fonts\.googleapis\.com|fonts\.gstatic\.com/i);
    expect(styles).not.toMatch(/@import\s+url\(["']?https?:/i);
    expect(styles).toContain("system-ui");
    expect(styles).toContain("ui-monospace");
  });

  it("bounds slow request headers and bodies at the public proxy", () => {
    const caddy = readFileSync(caddyFile, "utf8");

    expect(caddy).toMatch(/timeouts\s*\{[^}]*read_body\s+60s/s);
    expect(caddy).toMatch(/timeouts\s*\{[^}]*read_header\s+10s/s);
  });

  function detectVolume(extraEnvironment: Record<string, string> = {}) {
    return execFileSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: join(temporaryDirectory, "missing.env"),
        ...extraEnvironment
      }
    }).trim();
  }

  function baseEnvironment(): NodeJS.ProcessEnv {
    return {
      ...process.env,
      ADDRESS_ATLAS_PROD_ENV_FILE: hermeticEnvFile,
      ADDRESS_ATLAS_POSTGRES_VOLUME: "",
      ADDRESS_ATLAS_CADDY_DATA_VOLUME: "",
      ADDRESS_ATLAS_CADDY_CONFIG_VOLUME: "",
      ADDRESS_ATLAS_DOMAIN: "sync.test.invalid",
      ACME_EMAIL: "ops@test.invalid",
      SYNC_DATABASE_URL: "postgresql://address_atlas:test@postgres:5432/address_atlas_sync",
      SYNC_SESSION_SECRET: "test-only-session-secret-at-least-32-bytes",
      PASSKEY_RP_ID: "sync.test.invalid",
      PASSKEY_RP_NAME: "Address Atlas Test",
      POSTGRES_PASSWORD: "test-only-postgres-password",
      COMPOSE_PROJECT_NAME: "",
      DOCKER_BIN: fakeDocker,
      FAKE_DOCKER_POSTGRES_VOLUMES: "",
      FAKE_DOCKER_CADDY_DATA_VOLUMES: "",
      FAKE_DOCKER_CADDY_CONFIG_VOLUMES: "",
      FAKE_DOCKER_UNSCOPED_POSTGRES_VOLUMES: "",
      FAKE_DOCKER_UNSCOPED_CADDY_DATA_VOLUMES: "",
      FAKE_DOCKER_UNSCOPED_CADDY_CONFIG_VOLUMES: "",
      FAKE_DOCKER_ALL_VOLUMES: "",
      FAKE_DOCKER_RUNNING_POSTGRES: "",
      FAKE_DOCKER_RUNNING_CADDY_DATA: "",
      FAKE_DOCKER_RUNNING_CADDY_CONFIG: "",
      FAKE_DOCKER_LS_FAIL: "0",
      FAKE_DOCKER_PS_FAIL: "0",
      FAKE_DOCKER_LOG: "",
      FAKE_DOCKER_COMPOSE_ENV: ""
    };
  }
});

describe("release doctor invariants", () => {
  let temporaryDirectory: string;

  beforeEach(() => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "address-atlas-release-doctor-"));
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
  });

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
  });

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
  });

  function installExecutable(name: string, body: string) {
    const path = join(temporaryDirectory, name);
    writeFileSync(path, `#!/bin/sh\n${body}\n`);
    chmodSync(path, 0o755);
  }

  function runReleaseDoctor(identity: string, args: string[] = []) {
    installExecutable("docker", "exit 0");
    return spawnSync("bash", [releaseDoctor, ...args], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${temporaryDirectory}:/usr/bin:/bin`,
        ADDRESS_ATLAS_PROD_ENV_FILE: "",
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
        DOCKER_BIN: join(temporaryDirectory, "docker")
      }
    });
  }
});
