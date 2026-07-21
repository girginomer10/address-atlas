import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  LATEST_SYNC_MIGRATION_VERSION,
  MAX_COMPATIBLE_SYNC_MIGRATION_VERSION,
  SYNC_MIGRATION_CHAIN_CHECKSUMS
} from "./postgres-migrations";

const repoRoot = resolve(import.meta.dirname, "../../..");
const manageScript = join(repoRoot, "server/sync/manage-prod.sh");
const composeFile = join(repoRoot, "server/sync/compose.prod.yml");
const developmentComposeFile = join(repoRoot, "compose.sync.yml");
const dockerfile = join(repoRoot, "server/sync/Dockerfile");
const nativeConfigStateTool = join(repoRoot, "server/sync/native-config-deploy-state.mjs");
const nativeConfigJson = '{"schemaVersion":1,"configVersion":5,"updatedAt":"2026-07-20T00:00:00.000Z","refreshAfterSeconds":21600,"minSupportedAppVersion":"0.2.0","priceBaseUrl":"https://api.coingecko.com/api/v3/simple/price","chains":{"bitcoin":{"restUrl":"https://blockstream.info/api"}},"exchanges":{}}';
const nativeConfigDigest = execFileSync(process.execPath, [nativeConfigStateTool, "fingerprint"], {
  encoding: "utf8",
  input: nativeConfigJson
}).trim().split("|")[1]!;

describe("production sync deployment invariants", () => {
  let temporaryDirectory: string;
  let fakeDocker: string;
  let fakeGit: string;
  let fakeBackup: string;
  let fakeCurl: string;
  let hermeticEnvFile: string;

  beforeEach(() => {
    temporaryDirectory = realpathSync(mkdtempSync(join(tmpdir(), "address-atlas-deploy-")));
    hermeticEnvFile = join(temporaryDirectory, "production.env");
    writeFileSync(hermeticEnvFile, [
      "ADDRESS_ATLAS_DOMAIN=sync.test.invalid",
      "ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady",
      "NATIVE_ENDPOINT_CONFIG_VERSION=5",
      ""
    ].join("\n"), { mode: 0o600 });
    fakeGit = join(temporaryDirectory, "git");
    writeFileSync(fakeGit, `#!/bin/sh
case "$*" in
  *" rev-parse "*"^{tree}") printf '%s\\n' 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ;;
  *" rev-parse HEAD") printf '%s\\n' '0123456789abcdef0123456789abcdef01234567' ;;
  *" rev-parse refs/remotes/origin/main") printf '%s\\n' "\${FAKE_GIT_ORIGIN_MAIN:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" symbolic-ref --quiet --short HEAD") printf '%s\\n' "\${FAKE_GIT_BRANCH:-main}" ;;
  *" fetch --quiet --no-tags origin refs/heads/main:refs/remotes/origin/main") exit "\${FAKE_GIT_FETCH_STATUS:-0}" ;;
  *" merge-base --is-ancestor "*) exit "\${FAKE_GIT_ANCESTOR_STATUS:-0}" ;;
  *" cat-file -e "*"^{commit}") exit "\${FAKE_GIT_CAT_FILE_STATUS:-0}" ;;
  *" status --porcelain --untracked-files=normal") printf '%s' "\${FAKE_GIT_DIRTY:-}" ;;
  *" archive --format=tar --output="*)
    output=''
    for argument in "$@"; do
      case "$argument" in --output=*) output="\${argument#--output=}" ;; esac
    done
    [ -n "$output" ] || exit 70
    /usr/bin/git -C "$FAKE_GIT_ARCHIVE_ROOT" archive --format=tar --output="$output" HEAD || exit $?
    /usr/bin/tar -rf "$output" -C "$FAKE_GIT_ARCHIVE_ROOT" \
      server/sync/compose.prod.yml \
      server/sync/Dockerfile \
      server/sync/Caddyfile \
      server/sync/postgres-backup.sh \
      server/sync/migrate-restored-database.sh \
      server/sync/provision-restored-database.sh \
      server/sync/provision-runtime-role.sh \
      server/sync/bootstrap-database-roles.sh \
      server/sync/manage-prod.sh \
      server/sync/credential-rotation-state.mjs \
      server/sync/native-config-deploy-state.mjs || exit $?
    exit 0
    ;;
  *) exit 70 ;;
esac
`);
    chmodSync(fakeGit, 0o755);
    fakeBackup = join(temporaryDirectory, "backup");
    writeFileSync(fakeBackup, `#!/bin/sh
if [ -n "\${FAKE_BACKUP_LOG:-}" ]; then
  printf '%s\\n' "$*" >> "$FAKE_BACKUP_LOG"
fi
if [ -n "\${FAKE_ORDER_LOG:-}" ]; then
  printf 'backup:%s\\n' "$*" >> "$FAKE_ORDER_LOG"
fi
fake_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}
if [ -n "\${FAKE_BACKUP_ENV_LOG:-}" ]; then
  printf '%s\\n' \
    "signing_private=\${ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE:-}" \
    "signing_public=\${ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE:-}" \
    "offsite_required=\${ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED:-}" \
    "offsite_hook=\${ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK:-}" \
    "admin_password=\${POSTGRES_ADMIN_PASSWORD:-}" \
    "runtime_password=\${POSTGRES_RUNTIME_PASSWORD:-}" \
    "migration_hook=\${ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK:-}" \
    "provision_hook=\${ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK:-}" \
    "restore_revision=\${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}" \
    "restore_image=\${ADDRESS_ATLAS_RESTORE_IMAGE:-}" \
    "provision_image=\${ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE:-}" \
    "native_config_version=\${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION:-}" \
    "native_config_digest=\${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256:-}" \
    "native_config_updated_at=\${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS:-}" \
    "native_config_revision=\${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION:-}" \
    > "$FAKE_BACKUP_ENV_LOG"
fi
case "$1" in
  create|create-predeploy)
    [ "\${FAKE_BACKUP_CREATE_STATUS:-0}" = "0" ] || exit "$FAKE_BACKUP_CREATE_STATUS"
    printf '%s\\n' "\${FAKE_BACKUP_PATH:-/tmp/address-atlas-test.dump.age}"
    ;;
  verify) exit "\${FAKE_BACKUP_VERIFY_STATUS:-0}" ;;
  latest)
    [ "\${FAKE_BACKUP_LATEST_STATUS:-0}" = "0" ] || exit "$FAKE_BACKUP_LATEST_STATUS"
    printf '%s\\n' "\${FAKE_BACKUP_PATH:-/tmp/address-atlas-test.dump.age}"
    ;;
  drill) exit "\${FAKE_BACKUP_DRILL_STATUS:-0}" ;;
  restore) exit "\${FAKE_BACKUP_RESTORE_STATUS:-0}" ;;
  inspect)
    printf 'BACKUP_METADATA|4|%s|%s|%s|%s|%s|%s|%s|%s|%s|2026-07-20T00:00:00Z\\n' \
      "\${FAKE_BACKUP_SHA256:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}" \
      "\${FAKE_BACKUP_DATABASE:-address_atlas_sync}" \
      "\${FAKE_BACKUP_CONFIG_VERSION:-5}" \
      "\${FAKE_BACKUP_CONFIG_DIGEST:-${nativeConfigDigest}}" \
      "\${FAKE_BACKUP_CONFIG_UPDATED_AT:-1784505600000}" \
      "\${FAKE_BACKUP_CONFIG_REVISION:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
      "\${FAKE_BACKUP_SOURCE_WEB_IMAGE:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
      "\${FAKE_BACKUP_SOURCE_POSTGRES_IMAGE:-sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}" \
      "\${FAKE_BACKUP_MIGRATION_HEAD:-3}"
    ;;
  bootstrap-restore)
    [ "\${FAKE_BACKUP_BOOTSTRAP_STATUS:-0}" = "0" ] || exit "$FAKE_BACKUP_BOOTSTRAP_STATUS"
    migration_digest="$(fake_sha256 "$ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK")"
    provision_digest="$(fake_sha256 "$ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK")"
    provision_source_digest="$(fake_sha256 "$(dirname "$ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK")/provision-runtime-role.sh")"
    bootstrap_source_digest="$(fake_sha256 "$(dirname "$ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK")/bootstrap-database-roles.sh")"
    [ -z "\${FAKE_BOOTSTRAP_COMPLETED_STATE:-}" ] \
      || printf '%s\\n' completed > "$FAKE_BOOTSTRAP_COMPLETED_STATE"
    printf 'Bootstrap mock completed.\\n'
    printf 'BOOTSTRAP_RESTORE_RECEIPT|%s|%s|%s|%s|%s|%s|%s|sha256:%s|%s|%s|%s|%s|3|%s|%s|%s|%s\\n' \
      "\${FAKE_BACKUP_RECEIPT_SHA256:-\${FAKE_BACKUP_SHA256:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}}" \
      "\${FAKE_BACKUP_CONFIG_VERSION:-5}" \
      "\${FAKE_BACKUP_CONFIG_DIGEST:-${nativeConfigDigest}}" \
      "\${FAKE_BACKUP_CONFIG_UPDATED_AT:-1784505600000}" \
      "\${FAKE_BACKUP_CONFIG_REVISION:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
      "\${FAKE_BACKUP_SOURCE_WEB_IMAGE:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
      "\${FAKE_BACKUP_DATABASE:-address_atlas_sync}" \
      "\${FAKE_BOOTSTRAP_STORAGE_HEX:-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee}" \
      "\${FAKE_BOOTSTRAP_QUARANTINE:-address_atlas_sync_empty_20260720}" \
      "\${ADDRESS_ATLAS_RESTORE_BUILD_REVISION}" \
      "\${FAKE_BACKUP_TARGET_WEB_IMAGE:-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
      "\${FAKE_BACKUP_TARGET_PROVISION_IMAGE:-sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}" \
      "$migration_digest" "$provision_digest" "$provision_source_digest" \
      "$bootstrap_source_digest"
    ;;
  bootstrap-finalize)
    exit "\${FAKE_BACKUP_FINALIZE_STATUS:-0}"
    ;;
  classify-source) printf '%s\n' "\${FAKE_BACKUP_SOURCE_CLASSIFICATION:-existing-or-ambiguous}" ;;
  assert-lock) exit "\${FAKE_BACKUP_ASSERT_LOCK_STATUS:-0}" ;;
  bootstrap-lock-run)
    [ "$2" = "--" ] || exit 64
    shift 2
    ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID="$$" \
      ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION="\${FAKE_BOOTSTRAP_TARGET_REVISION:-0123456789abcdef0123456789abcdef01234567}" \
      "$@"
    ;;
  lock-run)
    [ "$2" = "--" ] || exit 64
    shift 2
    ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID="$$" "$@"
    ;;
  *) exit 64 ;;
esac
    `);
    chmodSync(fakeBackup, 0o755);
    fakeCurl = join(temporaryDirectory, "curl");
    writeFileSync(fakeCurl, `#!/bin/sh
url=""
headers=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-header) shift; headers="$1" ;;
    --output) shift; output="$1" ;;
    http*) url="$1" ;;
  esac
  shift
done
if [ -n "\${FAKE_CURL_STATE:-}" ] \
  && ! printf '%s' "$url" | grep -q 'deployment_probe=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; then
  count=0
  [ ! -f "$FAKE_CURL_STATE" ] || count="$(cat "$FAKE_CURL_STATE")"
  if [ "$count" -lt "\${FAKE_CURL_FAIL_COUNT:-0}" ]; then
    count=$((count + 1))
    printf '%s' "$count" > "$FAKE_CURL_STATE"
    exit 22
  fi
fi
case "$url" in
  */livez|*/healthz) printf '%s' '{"ok":true,"service":"address-atlas-sync"}' ;;
  */config/native*)
    revision='0123456789abcdef0123456789abcdef01234567'
    printf '%s' "$url" | grep -q 'deployment_probe=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      && revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    [ -z "\${FAKE_CONFIG_REVISION_OVERRIDE:-}" ] || revision="$FAKE_CONFIG_REVISION_OVERRIDE"
    if [ -n "$output" ] && [ -n "$headers" ]; then
      printf '%s' "$FAKE_NATIVE_CONFIG_JSON" > "$output"
      printf '%s\\r\\n' \\
        'HTTP/2 200' \\
        'content-type: application/json; charset=utf-8' \\
        'cache-control: no-store' \\
        "etag: \\"sha256-$FAKE_NATIVE_CONFIG_DIGEST\\"" \\
        "x-address-atlas-build-revision: $revision" \\
        '' > "$headers"
    else
      printf '%s' "$FAKE_NATIVE_CONFIG_JSON"
    fi
    ;;
  *) exit 22 ;;
esac
`);
    chmodSync(fakeCurl, 0o755);
    fakeDocker = join(temporaryDirectory, "docker");
    writeFileSync(fakeDocker, `#!/bin/sh
if [ -n "\${FAKE_DOCKER_LOG:-}" ]; then
  printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
fi
if [ -n "\${FAKE_ORDER_LOG:-}" ]; then
  printf 'docker:%s\\n' "$*" >> "$FAKE_ORDER_LOG"
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
if [ "$1" = "inspect" ]; then
  case "$*" in
    *"/var/lib/postgresql/data"*) printf 'volume|%s\n' "\${FAKE_DOCKER_POSTGRES_MOUNT_VOLUME:-address-atlas-prod-postgres}" ;;
    *"{{.Image}}|{{.Config.Image}}"*)
      printf '%s|%s\\n' \
        'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        'postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
      ;;
    *"org.opencontainers.image.revision"*)
      last_argument=''
      for argument in "$@"; do last_argument="$argument"; done
      runtime_revision=''
      [ ! -f "\${FAKE_DOCKER_RUNTIME_STATE:-/nonexistent}" ] || runtime_revision="$(cat "$FAKE_DOCKER_RUNTIME_STATE")"
      if [ "$last_argument" = "previous-web-container" ] \
        || printf '%s' "$last_argument" | grep -q 'aaaaaaaa' \
        || [ "$runtime_revision" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]; then
        image='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      else
        image='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        revision='0123456789abcdef0123456789abcdef01234567'
      fi
      running=true
      if [ -n "\${FAKE_DOCKER_FRONTEND_STOP_STATE:-}" ] \
          && [ -f "$FAKE_DOCKER_FRONTEND_STOP_STATE" ] \
          && grep -Fqx "$last_argument" "$FAKE_DOCKER_FRONTEND_STOP_STATE"; then
        running=false
      fi
      case "$*" in
        *"com.docker.compose.project"*)
          service=web
          printf '%s' "$last_argument" | grep -q 'caddy' && service=caddy
          printf '%s|address-atlas-sync|%s|%s|%s\n' \
            "$running" "$service" "$image" "$revision"
          ;;
        *"State.Running"*)
          [ "$last_argument" != "first-install-web" ] || running=false
          printf '%s|%s|%s\n' "$image" "$revision" "$running"
          ;;
        *) printf '%s|%s\n' "$image" "$revision" ;;
      esac
      ;;
    *"{{.State.Running}}"*) printf '%s\n' true ;;
    *"{{if .State.Health}}"*)
      last_argument=''
      for argument in "$@"; do last_argument="$argument"; done
      if [ "$last_argument" = "\${FAKE_DOCKER_POSTGRES_CONTAINER:-postgres-container}" ]; then
        printf '%s\\n' "\${FAKE_DOCKER_POSTGRES_HEALTH:-healthy}"
      elif [ -n "\${FAKE_BOOTSTRAP_COMPLETED_STATE:-}" ] \
          && [ -f "$FAKE_BOOTSTRAP_COMPLETED_STATE" ]; then
        printf '%s\\n' healthy
      else
        printf '%s\\n' "\${FAKE_DOCKER_HEALTH:-healthy}"
      fi
      ;;
  esac
  exit 0
fi
if [ "$1" = "exec" ]; then
  case "$*" in
    *"wget -q -O - http://127.0.0.1:3000/config/native"*)
      printf '%s' '{"schemaVersion":1,"configVersion":5,"updatedAt":"2026-07-20T00:00:00.000Z","refreshAfterSeconds":21600,"minSupportedAppVersion":"0.2.0","priceBaseUrl":"https://api.coingecko.com/api/v3/simple/price","chains":{"bitcoin":{"restUrl":"https://blockstream.info/api"}},"exchanges":{}}'
      exit 0
      ;;
  esac
  cat >/dev/null
  exit 0
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  case "$*" in
    *"com.addressatlas.sync.compatible-schema-head-3-sha256"*)
      printf '%s\n' "\${FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN:-47ad43aa7438c5c8969f7c01162bb73eab8d51066abef482a03fed86a7890ee3}"
      ;;
    *"com.addressatlas.sync.compatible-schema-head-4-sha256"*)
      printf '%s\n' "\${FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN:-ceb0b725a162b5be512bf35e63ecaf178aa67e7c1335e2807a116f2ef7f65dfe}"
      ;;
    *"com.addressatlas.sync.compatible-schema-head-5-sha256"*)
      printf '%s\n' "\${FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN:-c101eabfc6cdf4252a5a58ac3320958818243e62375d12c4ff864499551cff39}"
      ;;
    *"com.addressatlas.sync.max-compatible-schema-head"*)
      printf '%s\n' "\${FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD:-5}"
      ;;
    *"org.opencontainers.image.revision"*)
      printf '%s|%s\n' \
        'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        '0123456789abcdef0123456789abcdef01234567'
      ;;
    *"{{.Id}}"*)
      printf '%s\\n' 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
      ;;
  esac
  exit 0
fi
if [ "$1" = "tag" ] || [ "$1" = "image" ] || [ "$1" = "rm" ]; then
  exit 0
fi
if [ "$1" = "stop" ]; then
  if [ -n "\${FAKE_DOCKER_FRONTEND_STOP_STATE:-}" ]; then
    : > "$FAKE_DOCKER_FRONTEND_STOP_STATE"
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --time) shift 2; continue ;;
        *) printf '%s\n' "$1" >> "$FAKE_DOCKER_FRONTEND_STOP_STATE" ;;
      esac
      shift
    done
  fi
  exit 0
fi
if [ "$1" = "start" ]; then
  [ -z "\${FAKE_DOCKER_FRONTEND_STOP_STATE:-}" ] \
    || rm -f "$FAKE_DOCKER_FRONTEND_STOP_STATE"
  exit 0
fi
if [ "$1" = "ps" ]; then
  [ "\${FAKE_DOCKER_PS_FAIL:-0}" = "1" ] && exit 73
  selected_volume=""
  selected_service=""
  include_stopped=false
  for argument in "$@"; do
    case "$argument" in
      volume=*) selected_volume="\${argument#volume=}" ;;
      label=com.docker.compose.service=*) selected_service="\${argument#label=com.docker.compose.service=}" ;;
      -aq) include_stopped=true ;;
    esac
  done
  if [ -n "$selected_service" ]; then
    case "$selected_service" in
      postgres) [ "\${FAKE_DOCKER_NO_POSTGRES_CONTAINER:-0}" = "1" ] || printf '%s\n' "\${FAKE_DOCKER_POSTGRES_CONTAINER:-postgres-container}" ;;
      web)
        if [ "$include_stopped" = true ]; then
          if [ -n "\${FAKE_DOCKER_CREATED_WEB_STATE:-}" ] && [ -f "$FAKE_DOCKER_CREATED_WEB_STATE" ]; then
            printf '%s\n' first-install-web
          else
            printf '%s\n' "\${FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS:-}"
          fi
        else
          if [ -f "\${FAKE_DOCKER_RUNTIME_STATE:-/nonexistent}" ]; then
            candidate=web-container
          else
            candidate="\${FAKE_DOCKER_WEB_CONTAINERS:-web-container}"
          fi
          if [ -z "\${FAKE_DOCKER_FRONTEND_STOP_STATE:-}" ] \
              || [ ! -f "$FAKE_DOCKER_FRONTEND_STOP_STATE" ] \
              || ! grep -Fqx "$candidate" "$FAKE_DOCKER_FRONTEND_STOP_STATE"; then
            printf '%s\n' "$candidate"
          fi
        fi ;;
      caddy) printf '%s\n' "\${FAKE_DOCKER_CADDY_CONTAINERS:-}" ;;
    esac
    exit 0
  fi
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
  case "$*" in
    *" create --no-build --no-deps web"*)
      [ -z "\${FAKE_DOCKER_CREATED_WEB_STATE:-}" ] || printf '%s\n' created > "$FAKE_DOCKER_CREATED_WEB_STATE"
      ;;
    *" run --rm --no-deps schema"*)
      exit "\${FAKE_DOCKER_SCHEMA_STATUS:-0}"
      ;;
    *" run --rm --no-deps db-provision"*)
      exit "\${FAKE_DOCKER_PROVISION_STATUS:-0}"
      ;;
    *" up -d --no-build"*)
      [ -z "\${FAKE_DOCKER_RUNTIME_STATE:-}" ] \
        || printf '%s\n' "$ADDRESS_ATLAS_BUILD_REVISION" > "$FAKE_DOCKER_RUNTIME_STATE"
      [ -z "\${FAKE_DOCKER_FRONTEND_STOP_STATE:-}" ] \
        || rm -f "$FAKE_DOCKER_FRONTEND_STOP_STATE"
      ;;
  esac
  exit 0
fi
exit 70
`);
    chmodSync(fakeDocker, 0o755);
  });

  afterEach(() => {
    spawnSync("chmod", ["-R", "u+w", temporaryDirectory]);
    rmSync(temporaryDirectory, { recursive: true, force: true });
  });

  it("uses a stable explicit volume for a first installation", () => {
    expect(detectVolume()).toBe("address-atlas-prod-postgres");
  });

  it("binds active and rollback-compatible schema heads into deploy artifacts", () => {
    const manageSource = readFileSync(manageScript, "utf8");
    const dockerfileSource = readFileSync(dockerfile, "utf8");
    expect(manageSource.match(/^EXPECTED_RESTORE_MIGRATION_HEAD=(\d+)$/m)?.[1])
      .toBe(String(LATEST_SYNC_MIGRATION_VERSION));
    expect(
      manageSource.match(/^MAX_COMPATIBLE_ROLLBACK_MIGRATION_HEAD=(\d+)$/m)?.[1]
    ).toBe(String(MAX_COMPATIBLE_SYNC_MIGRATION_VERSION));
    expect(
      dockerfileSource.match(
        /^LABEL com\.addressatlas\.sync\.max-compatible-schema-head=(\d+)$/m
      )?.[1]
    ).toBe(String(MAX_COMPATIBLE_SYNC_MIGRATION_VERSION));
    for (
      let version = LATEST_SYNC_MIGRATION_VERSION;
      version <= MAX_COMPATIBLE_SYNC_MIGRATION_VERSION;
      version += 1
    ) {
      const pattern = new RegExp(
        `^LABEL com\\.addressatlas\\.sync\\.compatible-schema-head-${version}-sha256=([0-9a-f]{64})$`,
        "m"
      );
      expect(dockerfileSource.match(pattern)?.[1])
        .toBe(SYNC_MIGRATION_CHAIN_CHECKSUMS[version - 1]);
      const managePattern = new RegExp(
        `^EXPECTED_MIGRATION_CHAIN_SHA256_${version}="([0-9a-f]{64})"$`,
        "m"
      );
      expect(manageSource.match(managePattern)?.[1])
        .toBe(SYNC_MIGRATION_CHAIN_CHECKSUMS[version - 1]);
    }
  });

  it("waits for final PostgreSQL PID 1 and TCP in every Compose healthcheck", () => {
    const expected =
      "grep -qx postgres /proc/1/comm && pg_isready -h 127.0.0.1 -U address_atlas -d address_atlas_sync";
    for (const path of [composeFile, developmentComposeFile]) {
      expect(readFileSync(path, "utf8")).toContain(expected);
    }
  });

  it("rejects a schema change before touching data when the rollback image is too old", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container",
        FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD: "2"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("Deploy the missing adjacent release first");
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).not.toContain(" build web");
    expect(dockerCalls).not.toContain(" run --rm --no-deps schema");
  });

  it("allows a prepared rollback image while applying the adjacent schema head", () => {
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_MIGRATION_HEAD: "2",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
  });

  it("accepts the exact contiguous prepared-head chain through database head 5", () => {
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_MIGRATION_HEAD: "5",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
  });

  it("rejects a mismatched exact chain at prepared database head 5", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_MIGRATION_HEAD: "5",
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN: "f".repeat(64),
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("required schema head 5");
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).not.toContain(" build web");
    expect(dockerCalls).not.toContain(" run --rm --no-deps schema");
  });

  it("rejects a rollback image whose maximum head is below prepared database head 5", () => {
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_MIGRATION_HEAD: "5",
        FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD: "4",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("rollback requires head 5");
  });

  it("allows a legacy unlabeled rollback image only at the already-active schema head", () => {
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_MIGRATION_HEAD: "3",
        FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD: "<no value>",
        FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN: "<no value>",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
  });

  it("rejects a legacy unlabeled rollback image before an adjacent schema advance", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_MIGRATION_HEAD: "2",
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD: "<no value>",
        FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN: "<no value>",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("unlabeled rollback image");
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).not.toContain(" build web");
    expect(dockerCalls).not.toContain(" run --rm --no-deps schema");
  });

  it("rejects a partial rollback schema-capability label set", () => {
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN: "<no value>",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("incomplete schema-capability label set");
  });

  it("rejects a rollback image whose claimed head has a different migration chain", () => {
    writeNativeConfigReceipt();
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container",
        FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD: "4",
        FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN: "f".repeat(64)
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("exact migration chain");
  });

  it("rejects missing, unknown, or extra wrapper arguments", () => {
    for (const args of [
      [],
      ["unknown"],
      ["up", "--remove-orphans"],
      ["restore"],
      ["restore", "/tmp/backup.dump.age", "--confirm"],
      ["bootstrap-restore"],
      ["bootstrap-restore", "/tmp/backup.dump.age", "--confirm"]
    ]) {
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

  it("loads the complete signed-backup and restore contract from the production environment file", () => {
    const backupEnvLog = join(temporaryDirectory, "backup-env.log");
    const signingPrivate = join(temporaryDirectory, "backup-signing-private.pem");
    const signingPublic = join(temporaryDirectory, "backup-signing-public.pem");
    const offsiteHook = join(temporaryDirectory, "upload-backup-set");
    const adminPassword = "admin_from_production_env_4Rx8Lm2Qs7Vz9Tr5";
    writeFileSync(hermeticEnvFile, [
      "ADDRESS_ATLAS_DOMAIN=sync.test.invalid",
      "ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady",
      "NATIVE_ENDPOINT_CONFIG_VERSION=5",
      `ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE=${signingPrivate}`,
      `ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE=${signingPublic}`,
      "ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED=true",
      `ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK=${offsiteHook}`,
      `POSTGRES_ADMIN_PASSWORD=${adminPassword}`,
      ""
    ].join("\n"));
    writeNativeConfigReceipt();

    execFileSync("bash", [manageScript, "backup"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE: "",
        ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE: "",
        ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED: "",
        ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK: "",
        POSTGRES_ADMIN_PASSWORD: "",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container",
        FAKE_BACKUP_ENV_LOG: backupEnvLog
      }
    });

    expect(readFileSync(backupEnvLog, "utf8")).toBe([
      `signing_private=${signingPrivate}`,
      `signing_public=${signingPublic}`,
      "offsite_required=true",
      `offsite_hook=${offsiteHook}`,
      `admin_password=${adminPassword}`,
      "runtime_password=runtime_test_7MdkP2Yw4Jq9Vs8Nx3Fb6Lc1Hr5Tz0Qa",
      "migration_hook=",
      "provision_hook=",
      "restore_revision=",
      "restore_image=",
      "provision_image=",
      "native_config_version=5",
      `native_config_digest=${nativeConfigDigest}`,
      "native_config_updated_at=1784505600000",
      "native_config_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ""
    ].join("\n"));
  });

  it("fails closed when multiple historical volumes exist", () => {
    const result = spawnSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: hermeticEnvFile,
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
        ADDRESS_ATLAS_PROD_ENV_FILE: hermeticEnvFile,
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
        ADDRESS_ATLAS_PROD_ENV_FILE: hermeticEnvFile,
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
        ADDRESS_ATLAS_PROD_ENV_FILE: hermeticEnvFile,
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
    writeFileSync(envFile, [
      "ADDRESS_ATLAS_DOMAIN=sync.test.invalid",
      "ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady",
      "NATIVE_ENDPOINT_CONFIG_VERSION=5",
      ""
    ].join("\n"), { mode: 0o600 });
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
    writeFileSync(envFile, [
      "COMPOSE_PROJECT_NAME=foreign-project",
      "ADDRESS_ATLAS_DOMAIN=sync.test.invalid",
      "ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady",
      "NATIVE_ENDPOINT_CONFIG_VERSION=5",
      ""
    ].join("\n"), { mode: 0o600 });

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

    const composeCalls = readFileSync(logFile, "utf8")
      .split("\n")
      .filter((line) => line.startsWith("compose "));
    expect(composeCalls.length).toBeGreaterThanOrEqual(4);
    expect(composeCalls.every((line) => line.includes("--project-name address-atlas-sync"))).toBe(true);
    expect(composeCalls.some((line) => line.includes(" build web"))).toBe(true);
    expect(composeCalls.some((line) => line.includes("--profile admin run --rm --no-deps schema"))).toBe(true);
    expect(composeCalls.some((line) => line.includes("--profile admin run --rm --no-deps db-provision"))).toBe(true);
    expect(composeCalls.some((line) => line.includes(" up -d --no-build --wait --wait-timeout 120"))).toBe(true);
    expect(composeCalls.some((line) => line.includes(" up -d --build"))).toBe(false);
  });

  it("uses the explicit one-time role bootstrap service without exposing an owner fallback to steady provisioning", () => {
    setHermeticDatabaseRoleMode("bootstrap");
    const logFile = join(temporaryDirectory, "docker.log");
    const output = execFileSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_DATABASE_ROLE_MODE: "bootstrap",
        FAKE_DOCKER_LOG: logFile
      }
    });

    const composeCalls = readFileSync(logFile, "utf8")
      .split("\n")
      .filter((line) => line.startsWith("compose "));
    expect(composeCalls.some((line) => line.includes(" run --rm --no-deps db-role-bootstrap"))).toBe(true);
    expect(composeCalls.some((line) => line.includes(" run --rm --no-deps db-provision"))).toBe(false);
    expect(output).toContain("Set ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady before the next deploy");
  });

  it("completes a brand-new installation without fabricating a backup of empty state", () => {
    setHermeticDatabaseRoleMode("bootstrap");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const backupLog = join(temporaryDirectory, "backup.log");
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_DATABASE_ROLE_MODE: "bootstrap",
        FAKE_BACKUP_SOURCE_CLASSIFICATION: "brand-new-empty",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PROVISION_STATUS: "65"
      }
    });

    if (result.status !== 0) {
      throw new Error(`first install failed (${result.status})\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}\ndocker:\n${readFileSync(dockerLog, "utf8")}`);
    }
    expect(result.stdout).toContain("crash-resumable first installation");
    expect(result.stdout).toContain("Database role bootstrap completed");
    const backupCalls = readFileSync(backupLog, "utf8");
    expect(backupCalls).toContain("classify-source");
    expect(backupCalls).not.toMatch(/(^|\n)create-predeploy(\n|$)/);
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).toContain(" build web");
    expect(dockerCalls).toContain(join(temporaryDirectory, "deploy-sources"));
    expect(dockerCalls).toContain(" create --no-build --no-deps web");
    expect(dockerCalls).toContain(" run --rm --no-deps db-role-bootstrap");
    expect(() => readFileSync(join(temporaryDirectory, "install-deployment.json"), "utf8")).toThrow();
    expect(readFileSync(join(temporaryDirectory, "native-config-deployment.json"), "utf8"))
      .toContain('"schemaVersion": 1');
  });

  it("uses the immutable tree for Compose and every native-config state operation", () => {
    setHermeticDatabaseRoleMode("bootstrap");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const nodeLog = join(temporaryDirectory, "node.log");
    const nodeWrapper = join(temporaryDirectory, "node");
    const deploySourceRoot = join(temporaryDirectory, "deploy-sources");
    const obsoleteCache = join(deploySourceRoot, `${"f".repeat(40)}-${"d".repeat(40)}`);
    mkdirSync(obsoleteCache, { recursive: true, mode: 0o700 });
    chmodSync(deploySourceRoot, 0o700);
    writeFileSync(join(obsoleteCache, "obsolete"), "regenerable", { mode: 0o444 });
    chmodSync(obsoleteCache, 0o555);
    writeFileSync(nodeWrapper, `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_NODE_LOG"
exec "${process.execPath}" "$@"
`, { mode: 0o700 });
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_DATABASE_ROLE_MODE: "bootstrap",
        FAKE_BACKUP_SOURCE_CLASSIFICATION: "brand-new-empty",
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_NODE_LOG: nodeLog,
        NODE_BIN: nodeWrapper
      }
    });
    expect(result.status, result.stderr).toBe(0);

    const immutableRoot = join(
      temporaryDirectory,
      "deploy-sources",
      `0123456789abcdef0123456789abcdef01234567-${"e".repeat(40)}`
    );
    const immutableStateTool = join(immutableRoot, "server/sync/native-config-deploy-state.mjs");
    const nodeCalls = readFileSync(nodeLog, "utf8");
    expect(nodeCalls).toContain(immutableStateTool);
    expect(nodeCalls).not.toContain(nativeConfigStateTool);
    expect(readFileSync(dockerLog, "utf8")).toContain(
      `-f ${join(immutableRoot, "server/sync/compose.prod.yml")}`
    );
    expect(existsSync(obsoleteCache)).toBe(false);
  });

  it("rejects immutable-cache content, mode, and host-bind file-type drift", () => {
    setHermeticDatabaseRoleMode("bootstrap");
    const initial = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_DATABASE_ROLE_MODE: "bootstrap",
        FAKE_BACKUP_SOURCE_CLASSIFICATION: "brand-new-empty"
      }
    });
    expect(initial.status, initial.stderr).toBe(0);
    const immutableRoot = join(
      temporaryDirectory,
      "deploy-sources",
      `0123456789abcdef0123456789abcdef01234567-${"e".repeat(40)}`
    );
    const runAgainstCache = () => spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: { ...baseEnvironment(), FAKE_BACKUP_SOURCE_CLASSIFICATION: "existing-or-ambiguous" }
    });
    const expectCacheRejection = () => {
      const result = runAgainstCache();
      expect(result.status).toBe(67);
      expect(result.stderr).toContain("cache differs from the immutable Git tree");
    };

    const cachedCaddy = join(immutableRoot, "server/sync/Caddyfile");
    const caddyContents = readFileSync(join(repoRoot, "server/sync/Caddyfile"));
    chmodSync(cachedCaddy, 0o644);
    writeFileSync(cachedCaddy, Buffer.concat([caddyContents, Buffer.from("\n# drift\n")]));
    chmodSync(cachedCaddy, 0o444);
    expectCacheRejection();
    chmodSync(cachedCaddy, 0o644);
    writeFileSync(cachedCaddy, caddyContents);
    chmodSync(cachedCaddy, 0o444);

    chmodSync(cachedCaddy, 0o644);
    expectCacheRejection();
    chmodSync(cachedCaddy, 0o444);

    const syncDirectory = join(immutableRoot, "server/sync");
    for (const name of ["Caddyfile", "bootstrap-database-roles.sh"]) {
      const cached = join(syncDirectory, name);
      const source = join(repoRoot, "server/sync", name);
      const contents = readFileSync(source);
      const normalizedMode = (statSync(source).mode & 0o111) === 0 ? 0o444 : 0o555;
      chmodSync(syncDirectory, 0o755);
      rmSync(cached);
      symlinkSync(source, cached);
      chmodSync(syncDirectory, 0o555);
      try {
        expectCacheRejection();
      } finally {
        chmodSync(syncDirectory, 0o755);
        rmSync(cached);
        writeFileSync(cached, contents, { mode: normalizedMode });
        chmodSync(cached, normalizedMode);
        chmodSync(syncDirectory, 0o555);
      }
    }
  }, 15_000);

  it("resumes an interrupted first install from its exact recorded image after main advances", () => {
    setHermeticDatabaseRoleMode("bootstrap");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const backupLog = join(temporaryDirectory, "backup.log");
    const first = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_DATABASE_ROLE_MODE: "bootstrap",
        FAKE_BACKUP_SOURCE_CLASSIFICATION: "brand-new-empty",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_SCHEMA_STATUS: "74"
      }
    });
    if (first.status !== 74) {
      throw new Error(`interrupted install returned ${first.status}\nstdout:\n${first.stdout}\nstderr:\n${first.stderr}\ndocker:\n${readFileSync(dockerLog, "utf8")}`);
    }
    expect(execFileSync(process.execPath, [
      nativeConfigStateTool,
      "install-read",
      join(temporaryDirectory, "install-deployment.json")
    ], { encoding: "utf8" })).toContain("candidate-ready|");

    const resumed = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_DATABASE_ROLE_MODE: "bootstrap",
        FAKE_BACKUP_SOURCE_CLASSIFICATION: "existing-or-ambiguous",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PROVISION_STATUS: "65",
        FAKE_GIT_ORIGIN_MAIN: "c".repeat(40)
      }
    });

    expect(resumed.status).toBe(0);
    expect(readFileSync(backupLog, "utf8")).toContain("create-predeploy");
    expect(() => readFileSync(join(temporaryDirectory, "install-deployment.json"), "utf8")).toThrow();
  }, 15_000);

  it("requires exact explicit confirmation to adopt a missing live config receipt", () => {
    const revision = "a".repeat(40);
    const expected = `ADOPT:${revision}:5:${nativeConfigDigest}`;
    const commonEnvironment = {
      ...baseEnvironment(),
      FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
    };
    const rejected = spawnSync("bash", [
      manageScript, "adopt-native-config", "--confirm", "ADOPT:wrong"
    ], { encoding: "utf8", env: commonEnvironment });
    expect(rejected.status).toBe(64);
    expect(rejected.stderr).toContain(expected);

    const untrustedRevision = spawnSync("bash", [
      manageScript, "adopt-native-config", "--confirm", expected
    ], {
      encoding: "utf8",
      env: { ...commonEnvironment, FAKE_GIT_ANCESTOR_STATUS: "1" }
    });
    expect(untrustedRevision.status).toBe(67);
    expect(untrustedRevision.stderr).toContain("not an ancestor of authoritative origin/main");

    const accepted = spawnSync("bash", [
      manageScript, "adopt-native-config", "--confirm", expected
    ], { encoding: "utf8", env: commonEnvironment });
    expect(accepted.status).toBe(0);
    expect(execFileSync(process.execPath, [
      nativeConfigStateTool,
      "read",
      join(temporaryDirectory, "native-config-deployment.json")
    ], { encoding: "utf8" })).toContain(`5|${nativeConfigDigest}|1784505600000|${revision}|`);
  });

  it("runs the isolated restore drill with immutable migration and provisioning hooks", () => {
    const backupLog = join(temporaryDirectory, "backup.log");
    const backupEnvLog = join(temporaryDirectory, "backup-env.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const result = spawnSync("bash", [manageScript, "restore-drill"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_BACKUP_LOG: backupLog,
        FAKE_BACKUP_ENV_LOG: backupEnvLog,
        FAKE_DOCKER_LOG: dockerLog
      }
    });
    expect(result.status, result.stderr).toBe(0);
    const immutableRoot = join(
      temporaryDirectory,
      "deploy-sources",
      `0123456789abcdef0123456789abcdef01234567-${"e".repeat(40)}`
    );
    const restoreEnvironment = readFileSync(backupEnvLog, "utf8");
    expect(restoreEnvironment).toContain(
      `migration_hook=${join(immutableRoot, "server/sync/migrate-restored-database.sh")}`
    );
    expect(restoreEnvironment).toContain(
      `provision_hook=${join(immutableRoot, "server/sync/provision-restored-database.sh")}`
    );
    expect(restoreEnvironment).toContain("restore_revision=0123456789abcdef0123456789abcdef01234567");
    expect(restoreEnvironment).toContain("provision_image=postgres:16.14-alpine3.24@sha256:");
    expect(readFileSync(backupLog, "utf8")).toMatch(
      /latest[\s\S]*drill \/tmp\/address-atlas-test\.dump\.age/
    );
    expect(readFileSync(dockerLog, "utf8")).toContain(" build web");
  });

  it("restores, provisions, privately preflights, and publicly verifies before returning service", () => {
    const revision = "a".repeat(40);
    const imageId = `sha256:${"a".repeat(64)}`;
    const stateFile = join(temporaryDirectory, "native-config-deployment.json");
    execFileSync(process.execPath, [
      nativeConfigStateTool,
      "write",
      stateFile,
      "5",
      nativeConfigDigest,
      "1784505600000",
      revision,
      imageId
    ]);
    const deploySourceRoot = join(temporaryDirectory, "deploy-sources");
    const previousCache = join(deploySourceRoot, `${revision}-${"b".repeat(40)}`);
    const obsoleteCache = join(deploySourceRoot, `${"f".repeat(40)}-${"d".repeat(40)}`);
    for (const cache of [previousCache, obsoleteCache]) {
      mkdirSync(cache, { recursive: true, mode: 0o700 });
      writeFileSync(join(cache, "regenerable"), "cache", { mode: 0o444 });
      chmodSync(cache, 0o555);
    }
    chmodSync(deploySourceRoot, 0o700);
    const backupPath = join(temporaryDirectory, "selected.dump.age");
    writeFileSync(backupPath, "opaque-test-fixture", { mode: 0o600 });
    const backupLog = join(temporaryDirectory, "backup.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const result = spawnSync("bash", [
      manageScript,
      "restore",
      backupPath,
      "--confirm",
      "RESTORE:address_atlas_sync"
    ], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_ALLOW_PRODUCTION_RESTORE: "YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container",
        FAKE_DOCKER_WEB_CONTAINERS: "previous-web-container",
        FAKE_DOCKER_FRONTEND_STOP_STATE: join(temporaryDirectory, "frontend-stop-state")
      }
    });
    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
    expect(readFileSync(backupLog, "utf8")).toContain(
      `restore ${backupPath} --confirm RESTORE:address_atlas_sync`
    );
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).toContain(" build web");
    expect(dockerCalls).toContain(" run --rm --no-deps db-provision");
    expect(dockerCalls).toContain(" up -d --no-build --wait --wait-timeout 120");
    expect(execFileSync(process.execPath, [nativeConfigStateTool, "read", stateFile], {
      encoding: "utf8"
    })).toContain("0123456789abcdef0123456789abcdef01234567|");
    expect(existsSync(previousCache)).toBe(true);
    expect(existsSync(obsoleteCache)).toBe(false);
  }, 15_000);

  it("rejects restore before build or replacement when an unlabeled rollback image cannot cover the current schema", () => {
    writeNativeConfigReceipt();
    const backupPath = join(temporaryDirectory, "selected.dump.age");
    writeFileSync(backupPath, "opaque-test-fixture", { mode: 0o600 });
    const backupLog = join(temporaryDirectory, "backup.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const result = spawnSync("bash", [
      manageScript,
      "restore",
      backupPath,
      "--confirm",
      "RESTORE:address_atlas_sync"
    ], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_ALLOW_PRODUCTION_RESTORE: "YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_BACKUP_MIGRATION_HEAD: "2",
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PREVIOUS_SCHEMA_HEAD: "<no value>",
        FAKE_DOCKER_PREVIOUS_SCHEMA_CHAIN: "<no value>",
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("unlabeled rollback image");
    expect(readFileSync(backupLog, "utf8").split("\n"))
      .not.toContain(`restore ${backupPath} --confirm RESTORE:address_atlas_sync`);
    expect(readFileSync(dockerLog, "utf8")).not.toContain(" build web");
  });

  it("recovers a fresh cluster through signed inspection, two-phase policy checks, current-only deploy, and finalize", () => {
    const backupPath = join(temporaryDirectory, "offsite.dump.age");
    const backupLog = join(temporaryDirectory, "backup.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    const orderLog = join(temporaryDirectory, "order.log");
    const completedState = join(temporaryDirectory, "bootstrap-completed");
    writeFileSync(backupPath, "opaque", { mode: 0o600 });

    const result = spawnSync("bash", [
      manageScript,
      "bootstrap-restore",
      backupPath,
      "--confirm",
      "BOOTSTRAP-RESTORE:address_atlas_sync"
    ], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE: "YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_ORDER_LOG: orderLog,
        FAKE_DOCKER_HEALTH: "unhealthy",
        FAKE_BOOTSTRAP_COMPLETED_STATE: completedState
      }
    });

    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("BOOTSTRAP_RESTORE_RECEIPT|");
    expect(result.stdout).toContain("live, receipt-bound, and finalized");
    const backupCalls = readFileSync(backupLog, "utf8");
    expect(backupCalls).toMatch(
      new RegExp(`inspect ${backupPath}[\\s\\S]*bootstrap-restore ${backupPath} --confirm BOOTSTRAP-RESTORE:address_atlas_sync[\\s\\S]*bootstrap-finalize --confirm BOOTSTRAP-FINALIZE:address_atlas_sync`)
    );
    const orderedCalls = readFileSync(orderLog, "utf8").split("\n");
    const privatePreflights = orderedCalls
      .map((line, index) => line.includes(" run --detach --name address-atlas-config-preflight-") ? index : -1)
      .filter((index) => index >= 0);
    const engineIndex = orderedCalls.findIndex((line) => line.startsWith("backup:bootstrap-restore "));
    const deployIndex = orderedCalls.findIndex((line) => line.includes(" up -d --no-build --wait --wait-timeout 120"));
    const finalizeIndex = orderedCalls.findIndex((line) => line.startsWith("backup:bootstrap-finalize "));
    expect(privatePreflights).toHaveLength(2);
    expect(privatePreflights[0]).toBeLessThan(engineIndex);
    expect(engineIndex).toBeLessThan(privatePreflights[1]!);
    expect(privatePreflights[1]).toBeLessThan(deployIndex);
    expect(deployIndex).toBeLessThan(finalizeIndex);
    expect(readFileSync(dockerLog, "utf8")).not.toContain("tag sha256:");
    expect(execFileSync(process.execPath, [
      nativeConfigStateTool,
      "read",
      join(temporaryDirectory, "native-config-deployment.json")
    ], { encoding: "utf8" })).toContain("0123456789abcdef0123456789abcdef01234567|");
  }, 15_000);

  it("keeps recovery unfinalized and never rolls back when the engine receipt differs", () => {
    const backupPath = join(temporaryDirectory, "offsite.dump.age");
    const backupLog = join(temporaryDirectory, "backup.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    writeFileSync(backupPath, "opaque", { mode: 0o600 });
    const result = spawnSync("bash", [
      manageScript,
      "bootstrap-restore",
      backupPath,
      "--confirm",
      "BOOTSTRAP-RESTORE:address_atlas_sync"
    ], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE: "YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_BACKUP_RECEIPT_SHA256: "f".repeat(64)
      }
    });
    expect(result.status).toBe(67);
    expect(result.stderr).toContain("receipt does not match");
    expect(readFileSync(backupLog, "utf8")).not.toContain("bootstrap-finalize");
    expect(readFileSync(dockerLog, "utf8")).not.toContain(" up -d --no-build --wait");
    expect(readFileSync(dockerLog, "utf8")).not.toContain("tag sha256:");
  }, 15_000);

  it("resumes through stale-lock reclaim using env-file-only credentials and an origin/main ancestor", () => {
    const backupPath = join(temporaryDirectory, "offsite.dump.age");
    const backupDirectory = join(temporaryDirectory, "backups");
    const backupLog = join(temporaryDirectory, "backup.log");
    mkdirSync(backupDirectory, { mode: 0o700 });
    writeFileSync(join(backupDirectory, ".bootstrap-restore.state"), "durable-test-state\n", { mode: 0o600 });
    writeFileSync(backupPath, "opaque", { mode: 0o600 });
    writeFileSync(hermeticEnvFile, [
      "ADDRESS_ATLAS_DOMAIN=sync.test.invalid",
      "ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady",
      "NATIVE_ENDPOINT_CONFIG_VERSION=5",
      "ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE=YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY",
      "ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM=YES_I_VERIFIED_STALE_OWNER",
      `ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256=${"d".repeat(64)}`,
      "POSTGRES_ADMIN_PASSWORD=admin_from_env_file_4Rx8Lm2Qs7Vz9Tr5Nc6Hw3Kp1Jf0Yb",
      ""
    ].join("\n"), { mode: 0o600 });

    const result = spawnSync("bash", [
      manageScript,
      "bootstrap-restore",
      backupPath,
      "--confirm",
      "BOOTSTRAP-RESTORE:address_atlas_sync"
    ], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_BACKUP_DIR: backupDirectory,
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE: "",
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM: "",
        ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256: "",
        POSTGRES_ADMIN_PASSWORD: "",
        FAKE_BACKUP_LOG: backupLog,
        FAKE_GIT_ORIGIN_MAIN: "c".repeat(40)
      }
    });

    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
    expect(readFileSync(backupLog, "utf8")).toContain(
      "bootstrap-lock-run -- "
    );
  }, 15_000);

  it("rejects a resume checkout that is not the exact durable target before Docker work", () => {
    const backupPath = join(temporaryDirectory, "offsite.dump.age");
    const backupDirectory = join(temporaryDirectory, "backups");
    const backupLog = join(temporaryDirectory, "backup.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    mkdirSync(backupDirectory, { mode: 0o700 });
    writeFileSync(join(backupDirectory, ".bootstrap-restore.state"), "durable-test-state\n", { mode: 0o600 });
    writeFileSync(backupPath, "opaque", { mode: 0o600 });
    const result = spawnSync("bash", [
      manageScript,
      "bootstrap-restore",
      backupPath,
      "--confirm",
      "BOOTSTRAP-RESTORE:address_atlas_sync"
    ], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_BACKUP_DIR: backupDirectory,
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE: "YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY",
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM: "YES_I_VERIFIED_STALE_OWNER",
        ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256: "d".repeat(64),
        FAKE_BOOTSTRAP_TARGET_REVISION: "e".repeat(40),
        FAKE_GIT_ORIGIN_MAIN: "c".repeat(40),
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog
      }
    });
    expect(result.status).toBe(67);
    expect(result.stderr).toContain("exact target revision recorded by durable recovery state");
    expect(existsSync(dockerLog)).toBe(false);
    expect(readFileSync(backupLog, "utf8")).not.toContain("inspect ");
  });

  it("blocks ordinary mutations while bootstrap recovery state exists", () => {
    const backupDirectory = join(temporaryDirectory, "backups");
    const backupLog = join(temporaryDirectory, "backup.log");
    const dockerLog = join(temporaryDirectory, "docker.log");
    mkdirSync(backupDirectory, { mode: 0o700 });
    writeFileSync(join(backupDirectory, ".bootstrap-restore.state"), "durable-test-state\n", { mode: 0o600 });
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_BACKUP_DIR: backupDirectory,
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_LOG: dockerLog
      }
    });
    expect(result.status).toBe(75);
    expect(result.stderr).toContain("unfinished fresh-cluster recovery");
    expect(existsSync(dockerLog)).toBe(false);
  });

  it("removes the locked production-environment snapshot after a stateful command", () => {
    writeNativeConfigReceipt();
    execFileSync("bash", [manageScript, "backup"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        TMPDIR: temporaryDirectory,
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container"
      }
    });
    expect(readdirSync(temporaryDirectory).filter((entry) =>
      entry.startsWith("address-atlas-production-env.")
    )).toEqual([]);
  });

  it("refuses a dirty checkout before backup, build, or schema mutation", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    const backupLog = join(temporaryDirectory, "backup.log");
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_GIT_DIRTY: " M server/sync/compose.prod.yml",
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_BACKUP_LOG: backupLog
      }
    });

    expect(result.status).toBe(65);
    expect(result.stderr).toContain("clean Git checkout");
    expect(() => readFileSync(dockerLog, "utf8")).toThrow();
    const lockCalls = readFileSync(backupLog, "utf8");
    expect(lockCalls).toContain("lock-run --");
    expect(lockCalls).not.toMatch(/(^|\n)(create|create-predeploy|classify-source)(\n|$)/);
  });

  it("fails closed when the encrypted pre-deploy backup cannot be created", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_BACKUP_CREATE_STATUS: "74"
      }
    });

    expect(result.status).toBe(74);
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).not.toContain(" build web");
    expect(dockerCalls).not.toContain(" run --rm --no-deps schema");
  });

  it("keeps the verified frontend serving through every pre-deploy gate", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    const orderLog = join(temporaryDirectory, "order.log");
    writeNativeConfigReceipt();

    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_ORDER_LOG: orderLog,
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container",
        FAKE_DOCKER_WEB_CONTAINERS: "web-container",
        FAKE_DOCKER_CADDY_CONTAINERS: "caddy-container"
      }
    });

    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls.split("\n").some((line) => line.startsWith("stop "))).toBe(false);

    const orderedCalls = readFileSync(orderLog, "utf8").split("\n");
    const backupIndex = orderedCalls.findIndex((line) => line === "backup:create-predeploy");
    const buildIndex = orderedCalls.findIndex((line) => line.includes(" build web"));
    const schemaIndex = orderedCalls.findIndex((line) => line.includes(" run --rm --no-deps schema"));
    const privatePreflights = orderedCalls
      .map((line, index) => line.includes(" run --detach --name address-atlas-config-preflight-") ? index : -1)
      .filter((index) => index >= 0);
    const deployIndex = orderedCalls.findIndex((line) =>
      line.includes(" up -d --no-build --wait --wait-timeout 120")
    );
    expect(backupIndex).toBeGreaterThanOrEqual(0);
    expect(backupIndex).toBeLessThan(buildIndex);
    expect(buildIndex).toBeLessThan(schemaIndex);
    expect(privatePreflights).toHaveLength(2);
    expect(schemaIndex).toBeLessThan(privatePreflights[0]!);
    expect(privatePreflights[1]).toBeLessThan(deployIndex);
  });

  it("refuses to start or back up a stopped Postgres container mounted to a different volume", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    const backupLog = join(temporaryDirectory, "backup.log");
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_BACKUP_LOG: backupLog,
        FAKE_DOCKER_POSTGRES_MOUNT_VOLUME: "stale-or-wrong-postgres-volume"
      }
    });

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("does not mount the selected authoritative volume");
    expect(result.stderr).toContain("Refusing to start or back up the wrong database");
    expect(readFileSync(backupLog, "utf8")).toContain("lock-run --");
    expect(readFileSync(dockerLog, "utf8")).not.toContain(" build web");
  });

  it("rolls the web image back and still reports deployment failure when the public smoke fails", () => {
    const dockerLog = join(temporaryDirectory, "docker.log");
    execFileSync(process.execPath, [
      nativeConfigStateTool,
      "write",
      join(temporaryDirectory, "native-config-deployment.json"),
      "5",
      nativeConfigDigest,
      "1784505600000",
      "a".repeat(40),
      `sha256:${"a".repeat(64)}`
    ]);
    const result = spawnSync("bash", [manageScript, "up"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        FAKE_DOCKER_LOG: dockerLog,
        FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "previous-web-container",
        FAKE_CURL_FAIL_COUNT: "1"
      }
    });

    expect(result.status).toBe(70);
    expect(result.stderr).toContain("attempting the captured web-image rollback");
    expect(result.stdout).toContain("Rolled the web tier back to revision");
    const dockerCalls = readFileSync(dockerLog, "utf8");
    expect(dockerCalls).toContain("tag sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa address-atlas-sync:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    expect(dockerCalls.match(/ up -d --no-build --wait --wait-timeout 120/g)).toHaveLength(2);
  });

  function detectVolume(extraEnvironment: Record<string, string> = {}) {
    return execFileSync("bash", [manageScript, "detect-volume"], {
      encoding: "utf8",
      env: {
        ...baseEnvironment(),
        ADDRESS_ATLAS_PROD_ENV_FILE: hermeticEnvFile,
        ...extraEnvironment
      }
    }).trim();
  }

  function setHermeticDatabaseRoleMode(mode: "bootstrap" | "steady") {
    const current = readFileSync(hermeticEnvFile, "utf8");
    const updated = current.replace(
      /^ADDRESS_ATLAS_DATABASE_ROLE_MODE=.*$/m,
      `ADDRESS_ATLAS_DATABASE_ROLE_MODE=${mode}`
    );
    expect(updated).not.toBe(current);
    writeFileSync(hermeticEnvFile, updated, { mode: 0o600 });
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
      POSTGRES_PASSWORD: "owner_test_6Vr2Kx8Qm4Np7Ts9Lc3Hw5Jf1Zd0By8Ua",
      POSTGRES_ADMIN_PASSWORD: "admin_test_4Rx8Lm2Qs7Vz9Tr5Nc6Hw3Kp1Jf0Yb",
      POSTGRES_RUNTIME_PASSWORD: "runtime_test_7MdkP2Yw4Jq9Vs8Nx3Fb6Lc1Hr5Tz0Qa",
      ADDRESS_ATLAS_DATABASE_ROLE_MODE: "steady",
      ADDRESS_ATLAS_NATIVE_CONFIG_STATE_FILE: join(
        temporaryDirectory,
        "native-config-deployment.json"
      ),
      ADDRESS_ATLAS_INSTALL_STATE_FILE: join(
        temporaryDirectory,
        "install-deployment.json"
      ),
      ADDRESS_ATLAS_DEPLOY_SOURCE_ROOT: join(temporaryDirectory, "deploy-sources"),
      SYNC_SCHEMA_DATABASE_URL: "postgresql://address_atlas:owner_test_6Vr2Kx8Qm4Np7Ts9Lc3Hw5Jf1Zd0By8Ua@postgres:5432/address_atlas_sync",
      SYNC_REGISTRATION_ENABLED: "false",
      COMPOSE_PROJECT_NAME: "",
      DOCKER_BIN: fakeDocker,
      CURL_BIN: fakeCurl,
      GIT_BIN: fakeGit,
      FAKE_GIT_ARCHIVE_ROOT: repoRoot,
      ADDRESS_ATLAS_BACKUP_SCRIPT: fakeBackup,
      ADDRESS_ATLAS_SMOKE_ATTEMPTS: "1",
      FAKE_CURL_STATE: join(temporaryDirectory, "curl-state"),
      FAKE_CURL_FAIL_COUNT: "0",
      FAKE_NATIVE_CONFIG_JSON: nativeConfigJson,
      FAKE_NATIVE_CONFIG_DIGEST: nativeConfigDigest,
      FAKE_CONFIG_REVISION_OVERRIDE: "",
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
      FAKE_DOCKER_PREVIOUS_WEB_CONTAINERS: "",
      FAKE_DOCKER_POSTGRES_MOUNT_VOLUME: "address-atlas-prod-postgres",
      FAKE_DOCKER_LS_FAIL: "0",
      FAKE_DOCKER_PS_FAIL: "0",
      FAKE_DOCKER_LOG: "",
      FAKE_DOCKER_COMPOSE_ENV: "",
      FAKE_DOCKER_RUNTIME_STATE: join(temporaryDirectory, "docker-runtime-state"),
      FAKE_DOCKER_CREATED_WEB_STATE: join(temporaryDirectory, "docker-created-web-state")
    };
  }

  function writeNativeConfigReceipt() {
    execFileSync(process.execPath, [
      nativeConfigStateTool,
      "write",
      join(temporaryDirectory, "native-config-deployment.json"),
      "5",
      nativeConfigDigest,
      "1784505600000",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      `sha256:${"a".repeat(64)}`
    ]);
  }
});
