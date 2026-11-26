#!/usr/bin/env bash
# The SDK contract stack (docs-platform-0 15.6): node-auth-service,
# node-service-authz and node-service-docs, run from source against throwaway
# Postgres / Redis / Mongo / OpenFGA containers, with the auth and authz specs
# published to docs and ingested. The SDK repos' contract suites run against it.
#
#   stack.sh up      start everything, publish the specs, write the env file
#   stack.sh down    stop the services and remove the containers
#   stack.sh logs    print the service logs
#
# Local stack only: every URL it writes is localhost, and it never touches a
# cloud host. See README.md for the variables.
set -euo pipefail

NAME="${STACK_NAME:-sdk-contract}"
STATE_DIR="${STACK_STATE_DIR:-$PWD/.contract-stack}"
ENV_FILE="${STACK_ENV_FILE:-$STATE_DIR/env}"

AUTH_DIR="${STACK_AUTH_DIR:-}"
AUTHZ_DIR="${STACK_AUTHZ_DIR:-}"
DOCS_DIR="${STACK_DOCS_DIR:-}"

PG_PORT="${STACK_PG_PORT:-55432}"
REDIS_PORT="${STACK_REDIS_PORT:-56379}"
MONGO_PORT="${STACK_MONGO_PORT:-57017}"
FGA_PORT="${STACK_FGA_PORT:-58080}"
AUTH_PORT="${STACK_AUTH_PORT:-4200}"
AUTHZ_PORT="${STACK_AUTHZ_PORT:-4201}"
DOCS_PORT="${STACK_DOCS_PORT:-4370}"

ISSUER="https://auth.agrippa.local"
AUDIENCE="agrippa-api"
DOC_SPACE="${STACK_DOC_SPACE:-platform}"
WAIT_SECONDS="${STACK_WAIT_SECONDS:-120}"

log() { printf '[contract-stack] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

need_dir() {
  local label="$1" dir="$2"
  [ -n "$dir" ] || die "$label is not set (path to a checkout)"
  [ -f "$dir/package.json" ] || die "$label=$dir has no package.json"
}

# Wait until `curl -s -o /dev/null -w %{http_code} <args>` prints one of the
# expected codes (space separated).
wait_for() {
  local label="$1" expect="$2"; shift 2
  local code
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)
    case " $expect " in *" $code "*) log "$label ready ($code)"; return 0 ;; esac
    sleep 1
  done
  log "$label not ready after ${WAIT_SECONDS}s (last status: ${code:-none})"
  print_logs
  return 1
}

container() {
  local name="$NAME-$1"; shift
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" "$@" >/dev/null
  log "container $name started"
}

build_service() {
  local dir="$1"
  if [ ! -d "$dir/node_modules" ]; then
    (cd "$dir" && npm ci --no-audit --no-fund)
  fi
  if [ ! -f "$dir/dist/index.js" ]; then
    (cd "$dir" && npm run build)
  fi
}

start_service() {
  local label="$1" dir="$2" port="$3"; shift 3
  # A port someone else holds would make the health checks below pass against
  # the wrong process.
  if curl -s -o /dev/null --max-time 2 "http://localhost:$port/"; then
    die "port $port is already in use; stop what holds it or set the STACK_*_PORT variable"
  fi
  # exec: the recorded pid is node's own, so `down` stops the service itself.
  (cd "$dir" && exec env "$@" node dist/index.js </dev/null >"$STATE_DIR/$label.log" 2>&1) &
  echo $! >"$STATE_DIR/$label.pid"
  log "$label started (pid $!, log $STATE_DIR/$label.log)"
}

print_logs() {
  local f
  for f in "$STATE_DIR"/*.log; do
    [ -f "$f" ] || continue
    printf '\n===== %s (last 60 lines) =====\n' "$(basename "$f")" >&2
    tail -n 60 "$f" >&2
  done
}

dev_token() {
  # $1 = sub, $2 = scope. node-auth-service's /dev/token (never mounted in
  # production) signs a real RS256 token the other services verify by JWKS.
  curl -fsS -X POST "http://localhost:$AUTH_PORT/dev/token" \
    -H 'content-type: application/json' \
    -d "{\"sub\":\"$1\",\"scope\":\"$2\",\"expiresInSeconds\":3600}" |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).access_token))'
}

publish_spec() {
  # $1 = source key, $2 = display name, $3 = spec file, $4 = token
  local key="$1" name="$2" spec="$3" token="$4" version body code
  version=$(node -e 'process.stdout.write(String(require(process.argv[1]).info.version))' "$spec")
  body="$STATE_DIR/publish-$key.json"
  node -e '
    const [spec, name, space, out] = process.argv.slice(1)
    const doc = JSON.parse(require("fs").readFileSync(spec, "utf8"))
    require("fs").writeFileSync(out, JSON.stringify({ kind: "service", name, docSpaceKey: space, format: "openapi", document: doc }))
  ' "$spec" "$name" "$DOC_SPACE" "$body"
  code=$(curl -s -o "$STATE_DIR/publish-$key.out" -w '%{http_code}' -X PUT \
    "http://localhost:$DOCS_PORT/sources/$key/versions/$version" \
    -H "authorization: Bearer $token" -H 'content-type: application/json' --data-binary "@$body")
  case "$code" in
    200|201) log "published $key@$version ($code)" ;;
    *) cat "$STATE_DIR/publish-$key.out" >&2; die "publishing $key@$version failed ($code)" ;;
  esac
  wait_for "docs sdk-model $key@$version" "200" "http://localhost:$DOCS_PORT/sources/$key/versions/$version/sdk-model"
  printf '%s' "$version"
}

psql_auth() { docker exec "$NAME-postgres" psql -U ci -d auth -tAqc "$1"; }

json_field() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s)[process.argv[1]])))' "$1"; }

# The contract fixture: a platform admin (system.admin) who owns one
# organization. Signs up and logs in over HTTP like any user; the grants are
# written straight to this throwaway database, since granting system.admin has
# no API by design.
seed_fixture() {
  local jar="$STATE_DIR/fixture.cookies" user_id org
  FIXTURE_EMAIL="contract-admin-$(date +%s)@example.com"
  FIXTURE_PASSWORD="Contract-$(node -e 'process.stdout.write(require("crypto").randomBytes(12).toString("hex"))')-Aa1!"
  curl -fsS -o /dev/null -X POST "http://localhost:$AUTH_PORT/auth/signup/password" \
    -H 'content-type: application/json' -d "{\"email\":\"$FIXTURE_EMAIL\",\"password\":\"$FIXTURE_PASSWORD\"}"
  user_id=$(curl -fsS -c "$jar" -X POST "http://localhost:$AUTH_PORT/auth/login/password" \
    -H 'content-type: application/json' -d "{\"email\":\"$FIXTURE_EMAIL\",\"password\":\"$FIXTURE_PASSWORD\"}" | json_field userId)
  # GET/POST /organizations check the `system.admin` policy, which the seed
  # doesn't create; bind it to the system.admin role here.
  psql_auth "INSERT INTO policies (key, scope, effect, description)
      VALUES ('system.admin', 'global', 'allow', 'Platform administration (contract stack)') ON CONFLICT DO NOTHING;
    INSERT INTO role_policies (role_id, policy_id)
      SELECT r.id, p.id FROM roles r, policies p
      WHERE r.key = 'system.admin' AND r.scope = 'global' AND p.key = 'system.admin' ON CONFLICT DO NOTHING;
    INSERT INTO system_role_members (user_id, role_id)
      SELECT '$user_id', id FROM roles WHERE key = 'system.admin' AND scope = 'global' ON CONFLICT DO NOTHING" >/dev/null
  org=$(curl -fsS -b "$jar" -X POST "http://localhost:$AUTH_PORT/organizations" \
    -H 'content-type: application/json' -d '{"name":"Contract Org"}')
  FIXTURE_ORG_KEY=$(printf '%s' "$org" | json_field key)
  local org_id
  org_id=$(printf '%s' "$org" | json_field id)
  psql_auth "INSERT INTO organization_users (user_id, organization_id, status, joined_at)
      VALUES ('$user_id', '$org_id', 'active', now()) ON CONFLICT DO NOTHING;
    INSERT INTO user_roles (user_id, role_id, organization_id)
      SELECT '$user_id', id, '$org_id' FROM roles WHERE key = 'organization.owner' AND scope = 'global' ON CONFLICT DO NOTHING" >/dev/null
  rm -f "$jar"
  log "fixture: $FIXTURE_EMAIL owns organization $FIXTURE_ORG_KEY"
}

up() {
  need_dir STACK_AUTH_DIR "$AUTH_DIR"
  need_dir STACK_AUTHZ_DIR "$AUTHZ_DIR"
  need_dir STACK_DOCS_DIR "$DOCS_DIR"
  command -v docker >/dev/null || die "docker is required"
  mkdir -p "$STATE_DIR"

  container postgres -e POSTGRES_USER=ci -e POSTGRES_PASSWORD=ci -e POSTGRES_DB=auth \
    -p "$PG_PORT:5432" postgres:16-alpine
  container redis -p "$REDIS_PORT:6379" redis:7-alpine
  container mongo -p "$MONGO_PORT:27017" mongo:7
  # In-memory datastore: nothing to migrate, gone with the container.
  container openfga -p "$FGA_PORT:8080" openfga/openfga:latest run --datastore-engine memory

  log 'installing and building the services'
  build_service "$AUTH_DIR"
  build_service "$AUTHZ_DIR"
  build_service "$DOCS_DIR"

  for _ in $(seq 1 "$WAIT_SECONDS"); do
    docker exec "$NAME-postgres" pg_isready -h 127.0.0.1 -U ci -d auth >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$NAME-postgres" psql -U ci -d auth -qc 'CREATE DATABASE docs' >/dev/null 2>&1 || true

  local pg="postgres://ci:ci@localhost:$PG_PORT"

  # --- node-auth-service ---
  local auth_env=(
    NODE_ENV=development PORT="$AUTH_PORT" LOG_LEVEL=warn
    DATABASE_URL="$pg/auth" REDIS_URL="redis://localhost:$REDIS_PORT"
    MONGO_URL="mongodb://localhost:$MONGO_PORT/auth-pii" KAFKA_BROKERS=localhost:1
    SESSION_SECRET=contract-session-secret-not-for-prod OIDC_ISSUER="$ISSUER" OIDC_AUDIENCE="$AUDIENCE"
    RATE_LIMIT_MAX=100000 OTEL_EXPORTER_OTLP_ENDPOINT=
  )
  (cd "$AUTH_DIR" && DATABASE_URL="$pg/auth" npm run -s db:migrate)
  # The platform's system policies and roles (src/db/seed): auth doesn't seed
  # them on boot, a deploy does.
  (cd "$AUTH_DIR" && env "${auth_env[@]}" node -e '
    const { seedSystemPoliciesAndRoles } = require("./dist/db/seed")
    const { db } = require("./dist/db")
    seedSystemPoliciesAndRoles(db).then(() => process.exit(0), (err) => { console.error(err); process.exit(1) })
  ')
  start_service auth "$AUTH_DIR" "$AUTH_PORT" "${auth_env[@]}"
  wait_for "auth /health" "200" "http://localhost:$AUTH_PORT/health"
  # The login probe answers 401 once the session Redis client is connected.
  wait_for "auth login" "401" -X POST "http://localhost:$AUTH_PORT/auth/login/password" \
    -H 'content-type: application/json' -d '{"email":"probe@example.com","password":"x"}'

  seed_fixture

  # --- node-service-authz ---
  wait_for "openfga" "200" "http://localhost:$FGA_PORT/healthz"
  (cd "$AUTHZ_DIR" && OPENFGA_API_URL="http://localhost:$FGA_PORT" npm run -s fga:init)
  start_service authz "$AUTHZ_DIR" "$AUTHZ_PORT" \
    NODE_ENV=development PORT="$AUTHZ_PORT" LOG_LEVEL=warn \
    OPENFGA_API_URL="http://localhost:$FGA_PORT" \
    AUTHZ_ISSUER="$ISSUER" AUTHZ_AUDIENCE="$AUDIENCE" AUTHZ_JWKS_URI="http://localhost:$AUTH_PORT/jwks" \
    OTEL_EXPORTER_OTLP_ENDPOINT=
  wait_for "authz /health" "200" "http://localhost:$AUTHZ_PORT/health"

  # --- node-service-docs ---
  (cd "$DOCS_DIR" && DATABASE_URL="$pg/docs" npm run -s db:migrate)
  start_service docs "$DOCS_DIR" "$DOCS_PORT" \
    NODE_ENV=development PORT="$DOCS_PORT" LOG_LEVEL=warn DATABASE_URL="$pg/docs" \
    OIDC_ISSUER="$ISSUER" OIDC_AUDIENCE="$AUDIENCE" OIDC_JWKS_URI="http://localhost:$AUTH_PORT/jwks" \
    KAFKA_ENABLED=false DOCS_INGEST_POLL_INTERVAL_MS=500 AUTHZ_PDP_ENABLED=false \
    RATE_LIMIT_MAX=100000 OTEL_EXPORTER_OTLP_ENDPOINT=
  wait_for "docs /health" "200" "http://localhost:$DOCS_PORT/health"
  # The public platform doc space the specs land in. A platform space is made by
  # a platform admin (POST /spaces); in this throwaway database, seed it.
  docker exec "$NAME-postgres" psql -U ci -d docs -qc \
    "INSERT INTO doc_spaces (key, name, product_key, owner, visibility)
     VALUES ('$DOC_SPACE', 'Platform', 'platform', 'platform', 'public')
     ON CONFLICT DO NOTHING" >/dev/null

  # --- publish auth + authz to docs, as their CI does on merge (D1) ---
  local publish auth_version authz_version
  publish=$(dev_token svc-sdk-contract 'docs:publish')
  auth_version=$(publish_spec node-auth-service 'Auth service' "$AUTH_DIR/openapi.json" "$publish")
  authz_version=$(publish_spec node-service-authz 'Authorization service' "$AUTHZ_DIR/openapi.json" "$publish")

  cat >"$ENV_FILE" <<EOF
AGRIPPA_CONTRACT_AUTH_URL=http://localhost:$AUTH_PORT
AGRIPPA_CONTRACT_AUTHZ_URL=http://localhost:$AUTHZ_PORT
AGRIPPA_CONTRACT_DOCS_URL=http://localhost:$DOCS_PORT
AGRIPPA_CONTRACT_AUTH_VERSION=$auth_version
AGRIPPA_CONTRACT_AUTHZ_VERSION=$authz_version
AGRIPPA_CONTRACT_EMAIL=$FIXTURE_EMAIL
AGRIPPA_CONTRACT_PASSWORD=$FIXTURE_PASSWORD
AGRIPPA_CONTRACT_ORG_KEY=$FIXTURE_ORG_KEY
EOF
  log "stack up; env written to $ENV_FILE"
  grep -v PASSWORD "$ENV_FILE" >&2
}

down() {
  local f
  for f in "$STATE_DIR"/*.pid; do
    [ -f "$f" ] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
  for c in postgres redis mongo openfga; do
    docker rm -f "$NAME-$c" >/dev/null 2>&1 || true
  done
  log 'stack down'
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  logs) print_logs ;;
  *) echo "usage: $0 up|down|logs" >&2; exit 2 ;;
esac
