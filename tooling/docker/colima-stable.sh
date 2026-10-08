#!/usr/bin/env bash
#
# Run the published stable Reactive Resume image (v6) on a dedicated Colima profile.
#
# - The app runs from the registry image. This script never builds the checkout.
# - Postgres 18 keeps its data in a named Docker volume. The Colima VM disk is stored on the
#   SSD, so the database is on the SSD too.
# - Uploads, the generated .env and backups are ordinary folders under $DATA_DIR.
#
# Usage: tooling/docker/colima-stable.sh [command]
#
#   up          create or start everything (default); creates .env on the first run
#   down        stop containers; keeps the database, uploads and .env
#   stop        down, then stop the Colima profile
#   status      show profile, containers, health and disk locations
#   logs [-f]   show app logs; -f follows
#   backup      pg_dump plus a tarball of uploads into $DATA_DIR/backups
#   update      backup, pull the newest image for the current app image, then up
#   help        show usage
#
# Environment:
#   RR_PORT     host port on 127.0.0.1 (default 3000; pnpm dev also uses 3000)
#   RR_IMAGE    app image. Once set, it is remembered in $DATA_DIR/app-image, so later
#               commands keep it. Without it or a stamp, the stable v6 tag is used.
#
# Requires: colima, docker (with a Compose plugin), openssl, curl, lsof, and Homebrew's
# docker-compose (brew install docker-compose) unless another Compose plugin is installed.
# The script uses its own Docker client config (DOCKER_CONFIG), so registry logins in
# ~/.docker/config.json do not apply. The images it runs are public and pull anonymously.

set -euo pipefail

readonly SSD_ROOT="/Volumes/Mac SSD"
readonly DATA_DIR="$SSD_ROOT/reactive-resume"
readonly APP_IMAGE_STAMP="$DATA_DIR/app-image"
readonly PROFILE="reactive-resume"
readonly PROJECT="reactive-resume-stable"
readonly DEFAULT_APP_IMAGE="ghcr.io/reactive-resume/reactive-resume:v6"
# Set in main(): see resolve_app_image.
APP_IMAGE=""
readonly POSTGRES_IMAGE="postgres:18"
readonly RR_PORT="${RR_PORT:-3000}"
readonly VM_CPUS=4
readonly VM_MEMORY_GIB=4
readonly VM_DISK_GIB=30
readonly PROFILE_DIR="$HOME/.colima/$PROFILE"
readonly VM_DIR="$HOME/.colima/_lima/colima-$PROFILE"
readonly DOCKER_SOCKET="$PROFILE_DIR/docker.sock"
readonly CLIENT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/reactive-resume-colima/docker"
readonly MOUNT_CHECK_FILE="/app/data/.rr-mount-check"
readonly WRITE_CHECK="touch /app/data/.rr-write-check && rm -f /app/data/.rr-write-check"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [command]

Commands:
  up          start or create everything (default); creates .env on the first run
  down        stop containers; keeps the database, uploads and .env
  stop        down, then stop the Colima profile
  status      show profile, containers, health and disk locations
  logs [-f]   show app logs; -f follows
  backup      pg_dump plus a tarball of uploads into $DATA_DIR/backups
  update      backup, pull the newest image for the current app image, then up
  help        show this text

Environment:
  RR_PORT     host port on 127.0.0.1 (default 3000)
  RR_IMAGE    app image; remembered in $APP_IMAGE_STAMP (default $DEFAULT_APP_IMAGE)
EOF
}

# Mount point backing a path. Fields 6 onward, so spaces in "/Volumes/Mac SSD" survive.
mount_point_of() {
  df -P "$1" | awk 'NR == 2 { sub(/^([^ ]+ +){5}/, ""); print }'
}

require_commands() {
  local cmd
  for cmd in colima docker openssl curl lsof awk df tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
  done
}

require_ssd() {
  [ -d "$SSD_ROOT" ] && [ "$(mount_point_of "$SSD_ROOT")" = "$SSD_ROOT" ] ||
    die "$SSD_ROOT is not mounted"
}

# The Colima home must resolve to the SSD so the VM disk is stored there.
require_colima_home_on_ssd() {
  if [ ! -e "$HOME/.colima" ] && [ ! -L "$HOME/.colima" ]; then
    mkdir -p "$SSD_ROOT/.colima"
    ln -s "$SSD_ROOT/.colima" "$HOME/.colima"
    log "linked $HOME/.colima to $SSD_ROOT/.colima"
  fi
  local physical
  physical="$(cd -P "$HOME/.colima" 2>/dev/null && pwd -P)" || die "$HOME/.colima is a broken link"
  case "$physical" in
    "$SSD_ROOT"/*) ;;
    *) die "$HOME/.colima resolves to $physical, not $SSD_ROOT. Move Colima's home to the SSD first." ;;
  esac
}

# The Docker CLI reads cliPluginsExtraDirs from its config file only (no env var), so the script
# uses its own config directory and leaves the global ~/.docker/config.json alone.
find_compose_plugin_dir() {
  local brew_prefix dir
  brew_prefix="$(brew --prefix 2>/dev/null || true)"
  for dir in \
    "$brew_prefix/lib/docker/cli-plugins" \
    /opt/homebrew/lib/docker/cli-plugins \
    /usr/local/lib/docker/cli-plugins \
    "$HOME/.docker/cli-plugins" \
    /Applications/Docker.app/Contents/Resources/cli-plugins; do
    if [ -x "$dir/docker-compose" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

setup_docker_client() {
  local plugin_dir
  plugin_dir="$(find_compose_plugin_dir)" ||
    die "Docker Compose plugin not found. Install it with: brew install docker-compose"
  mkdir -p "$CLIENT_CONFIG_DIR"
  printf '{\n  "cliPluginsExtraDirs": ["%s"]\n}\n' "$plugin_dir" > "$CLIENT_CONFIG_DIR/config.json"
  export DOCKER_CONFIG="$CLIENT_CONFIG_DIR"
  export DOCKER_HOST="unix://$DOCKER_SOCKET"
  unset DOCKER_CONTEXT
  docker compose version >/dev/null 2>&1 ||
    die "docker compose does not run; check $CLIENT_CONFIG_DIR/config.json"
}

# Compose wrapper: every command targets this stack's project and files.
dc() {
  docker compose --project-name "$PROJECT" --project-directory "$DATA_DIR" --file "$DATA_DIR/compose.yml" "$@"
}

profile_running() {
  colima status --profile "$PROFILE" >/dev/null 2>&1
}

# Refuse to reuse a profile created with settings this script depends on.
check_profile_settings() {
  local config="$PROFILE_DIR/colima.yaml" key name expected value
  [ -f "$config" ] || return 0
  for key in vmType:vz mountType:virtiofs runtime:docker; do
    name="${key%%:*}"
    expected="${key#*:}"
    value="$(awk -F': *' -v k="$name" '$1 == k { print $2; exit }' "$config")"
    [ "$value" = "$expected" ] ||
      die "profile $PROFILE has $name=$value, expected $expected. Back up, then remove it with: colima delete --profile $PROFILE"
  done
}

wait_for_docker() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Docker in profile $PROFILE is not answering. Check: colima status --profile $PROFILE"
}

start_profile() {
  if profile_running; then
    return 0
  fi
  check_profile_settings
  if [ -f "$PROFILE_DIR/colima.yaml" ]; then
    log "starting Colima profile $PROFILE"
    colima start --profile "$PROFILE" --activate=false --ssh-config=false
  else
    log "creating Colima profile $PROFILE: $VM_CPUS CPUs, $VM_MEMORY_GIB GiB RAM, $VM_DISK_GIB GiB disk on $SSD_ROOT"
    colima start --profile "$PROFILE" --activate=false --ssh-config=false \
      --runtime docker --vm-type vz --mount-type virtiofs --arch aarch64 \
      --cpus "$VM_CPUS" --memory "$VM_MEMORY_GIB" --disk "$VM_DISK_GIB" \
      --mount "$SSD_ROOT:w"
  fi
}

verify_vm_disk_on_ssd() {
  local mount
  mount="$(mount_point_of "$VM_DIR")"
  [ "$mount" = "$SSD_ROOT" ] || die "Colima VM disk for $PROFILE is on [$mount], expected $SSD_ROOT"
}

prepare_data_dir() {
  # Resume data stays owner-only. The VM reaches these folders as the same host user.
  mkdir -p "$DATA_DIR/uploads" "$DATA_DIR/backups"
  chmod 700 "$DATA_DIR" "$DATA_DIR/uploads" "$DATA_DIR/backups"
  if [ ! -f "$DATA_DIR/.env" ]; then
    create_env_file
  fi
}

create_env_file() {
  local env_file="$DATA_DIR/.env" tmp="$DATA_DIR/.env.tmp"
  local pg_password auth_secret encryption_secret
  log "creating $env_file with generated secrets"
  pg_password="$(openssl rand -hex 32)"
  auth_secret="$(openssl rand -hex 32)"
  encryption_secret="$(openssl rand -hex 32)"
  (
    umask 077
    cat > "$tmp" <<EOF
# Generated by tooling/docker/colima-stable.sh. Keep this file with your backups:
# a restore needs the same AUTH_SECRET and ENCRYPTION_SECRET.
APP_URL="http://localhost:$RR_PORT"
DATABASE_URL="postgresql://postgres:$pg_password@postgres:5432/postgres"
POSTGRES_PASSWORD="$pg_password"
AUTH_SECRET="$auth_secret"
ENCRYPTION_SECRET="$encryption_secret"
STORAGE_BACKEND="local"
LOCAL_STORAGE_PATH="/app/data"
EOF
  )
  mv "$tmp" "$env_file"
}

check_app_url() {
  local current
  current="$(awk -F= '$1 == "APP_URL" { v = substr($0, index($0, "=") + 1); gsub(/"/, "", v); print v; exit }' "$DATA_DIR/.env")"
  case "$current" in
    http://localhost:* | http://127.0.0.1:*)
      [ "$current" = "http://localhost:$RR_PORT" ] ||
        warn "APP_URL in $DATA_DIR/.env is $current but RR_PORT is $RR_PORT. Set APP_URL to the address you open."
      ;;
  esac
}

check_postgres_stamp() {
  local stamp="$DATA_DIR/postgres-image" recorded
  [ -f "$stamp" ] || return 0
  recorded="$(cat "$stamp")"
  [ "$recorded" = "$POSTGRES_IMAGE" ] ||
    die "database was created by $recorded; this script runs $POSTGRES_IMAGE. Upgrade Postgres with pg_dump and pg_restore instead."
}

write_postgres_stamp() {
  printf '%s\n' "$POSTGRES_IMAGE" > "$DATA_DIR/postgres-image"
}

# RR_IMAGE, then the image the stack last started with, then the stable v6 tag. Without the stamp, a plain
# "up" after a nightly run would move the stack back to v6 and bring back bugs fixed since then.
resolve_app_image() {
  if [ -n "${RR_IMAGE:-}" ]; then
    printf '%s\n' "$RR_IMAGE"
  elif [ -f "$APP_IMAGE_STAMP" ]; then
    cat "$APP_IMAGE_STAMP"
  else
    printf '%s\n' "$DEFAULT_APP_IMAGE"
  fi
}

write_app_image_stamp() {
  printf '%s\n' "$APP_IMAGE" > "$APP_IMAGE_STAMP"
}

write_compose_file() {
  local tmp="$DATA_DIR/compose.yml.tmp"
  cat > "$tmp" <<EOF
# Generated by tooling/docker/colima-stable.sh. Rewritten on every up.
services:
  postgres:
    image: $POSTGRES_IMAGE
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  reactive-resume:
    image: $APP_IMAGE
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:$RR_PORT:3000"
    volumes:
      - type: bind
        source: "$DATA_DIR/uploads"
        target: /app/data
        bind:
          create_host_path: false
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
EOF
  mv "$tmp" "$DATA_DIR/compose.yml"
}

# Colima's user-mode network drops connections now and then; retry before giving up.
pull_image() {
  local image="$1" attempt
  for ((attempt = 1; attempt <= 4; attempt++)); do
    log "pulling $image (attempt $attempt of 4)"
    if docker pull "$image"; then
      return 0
    fi
    if [ "$attempt" -lt 4 ]; then
      sleep 15
    fi
  done
  die "could not pull $image. Check the network, then run: $0 up"
}

ensure_images() {
  local image
  for image in "$POSTGRES_IMAGE" "$APP_IMAGE"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      pull_image "$image"
    fi
  done
}

# Run a shell command as the given user inside the app image, with uploads mounted at /app/data.
app_run() {
  local user="$1" command="$2"
  docker run --rm --user "$user" --entrypoint sh \
    --mount "type=bind,source=$DATA_DIR/uploads,target=/app/data" \
    "$APP_IMAGE" -c "$command"
}

# Proves the Colima VM sees the SSD folder (a missing bind source would otherwise be created empty in the VM).
check_uploads_visible() {
  local marker="$DATA_DIR/uploads/.rr-mount-check" token seen
  token="$(openssl rand -hex 16)"
  printf '%s\n' "$token" > "$marker"
  if ! seen="$(app_run node "cat $MOUNT_CHECK_FILE" 2>&1)" || [ "$seen" != "$token" ]; then
    rm -f "$marker"
    die "the Colima VM cannot see $DATA_DIR/uploads (got: ${seen:-nothing}). Check that $SSD_ROOT is mounted in profile $PROFILE."
  fi
  rm -f "$marker"
}

# prepare_data_dir sets uploads to 700 just before this runs, so a failure means the host mount or
# ownership blocks writes from the VM. Fix that on the host; do not chown inside the VM.
ensure_uploads_writable() {
  local output
  if ! output="$(app_run node "$WRITE_CHECK" 2>&1)"; then
    die "$DATA_DIR/uploads is not writable by the app user (node) inside the VM: $output"
  fi
}

app_running() {
  [ -f "$DATA_DIR/compose.yml" ] && [ -n "$(dc ps --status running -q reactive-resume 2>/dev/null)" ]
}

check_port_free() {
  if app_running; then
    return 0
  fi
  if lsof -nP -iTCP:"$RR_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    lsof -nP -iTCP:"$RR_PORT" -sTCP:LISTEN >&2 || true
    die "port $RR_PORT is already in use (listed above). Pick another with: RR_PORT=3100 $0 up"
  fi
}

start_stack() {
  if ! dc up -d --wait --wait-timeout 180; then
    dc logs --tail=80 || true
    die "the stack did not become healthy; see the logs above"
  fi
}

verify_stack() {
  curl -fsS --max-time 10 "http://127.0.0.1:$RR_PORT/api/health" >/dev/null ||
    die "health check failed at http://127.0.0.1:$RR_PORT/api/health"
  local pg_id mount_type
  pg_id="$(dc ps -q postgres)"
  [ -n "$pg_id" ] || die "postgres container not found after startup"
  mount_type="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Type}}{{end}}{{end}}' "$pg_id")"
  [ "$mount_type" = "volume" ] || die "Postgres data is a $mount_type mount, expected a named volume"
}

print_summary() {
  local vm_disk
  vm_disk="$(cd -P "$VM_DIR" && pwd -P)/disk"
  cat <<EOF

Reactive Resume is running: http://localhost:$RR_PORT
  Create your account there.

  Settings   $DATA_DIR/.env
             Keep this file with backups: restores need the same AUTH_SECRET and ENCRYPTION_SECRET.
  Uploads    $DATA_DIR/uploads
  Backups    $DATA_DIR/backups   (make one with: $0 backup)
  Database   Docker volume ${PROJECT}_postgres_data on the Colima VM disk:
             $vm_disk
  Email      verification links go to the log until SMTP is set: $0 logs | grep -i verify
EOF
}

require_running_stack() {
  profile_running || die "Colima profile $PROFILE is not running. Start it with: $0 up"
  setup_docker_client
  [ -f "$DATA_DIR/compose.yml" ] || die "no compose file in $DATA_DIR. Start it with: $0 up"
  [ -n "$(dc ps --status running -q postgres 2>/dev/null)" ] || die "Postgres is not running. Start it with: $0 up"
}

cmd_up() {
  require_commands
  require_ssd
  require_colima_home_on_ssd
  if ! [[ "$RR_PORT" =~ ^[0-9]+$ ]] || [ "$RR_PORT" -lt 1 ] || [ "$RR_PORT" -gt 65535 ]; then
    die "RR_PORT must be a port number from 1 to 65535, got: $RR_PORT"
  fi
  setup_docker_client
  prepare_data_dir
  check_app_url
  check_postgres_stamp
  start_profile
  wait_for_docker
  verify_vm_disk_on_ssd
  write_compose_file
  ensure_images
  check_uploads_visible
  ensure_uploads_writable
  check_port_free
  start_stack
  write_postgres_stamp
  write_app_image_stamp
  verify_stack
  print_summary
}

cmd_down() {
  if ! profile_running; then
    log "Colima profile $PROFILE is not running; nothing to stop"
    return 0
  fi
  setup_docker_client
  if [ ! -f "$DATA_DIR/compose.yml" ]; then
    log "no compose file in $DATA_DIR; nothing to stop"
    return 0
  fi
  dc down
  log "containers stopped; database volume, uploads and .env are kept"
}

cmd_stop() {
  cmd_down
  if profile_running; then
    log "stopping Colima profile $PROFILE"
    colima stop --profile "$PROFILE"
  fi
}

cmd_status() {
  require_commands
  log "app image: $APP_IMAGE"
  if ! profile_running; then
    log "Colima profile $PROFILE: stopped (start with: $0 up)"
    return 0
  fi
  log "Colima profile $PROFILE: running"
  setup_docker_client
  if [ -f "$DATA_DIR/compose.yml" ]; then
    dc ps
  fi
  if curl -fsS --max-time 5 "http://127.0.0.1:$RR_PORT/api/health" >/dev/null 2>&1; then
    log "health: ok at http://localhost:$RR_PORT"
  else
    log "health: not answering on port $RR_PORT"
  fi
  log "VM disk: $(cd -P "$VM_DIR" && pwd -P)/disk (on $(mount_point_of "$VM_DIR"))"
  log "uploads: $(du -sh "$DATA_DIR/uploads" | awk '{ print $1 }') in $DATA_DIR/uploads"
}

cmd_logs() {
  local option="${1:-}"
  case "$option" in
    "" | -f) ;;
    *) die "unknown logs option: $option (use: logs or logs -f)" ;;
  esac
  require_running_stack
  if [ "$option" = "-f" ]; then
    dc logs -f --tail=200 reactive-resume
  else
    dc logs --tail=200 reactive-resume
  fi
}

cmd_backup() {
  require_running_stack
  umask 077
  local stamp dump archive
  stamp="$(date +%Y%m%d-%H%M%S)"
  dump="$DATA_DIR/backups/reactive-resume-$stamp.dump"
  archive="$DATA_DIR/backups/uploads-$stamp.tar.gz"
  log "dumping database to $dump"
  if ! dc exec -T postgres pg_dump -U postgres -d postgres --format=custom > "$dump.partial"; then
    rm -f "$dump.partial"
    die "pg_dump failed"
  fi
  mv "$dump.partial" "$dump"
  log "archiving uploads to $archive"
  tar -C "$DATA_DIR/uploads" -czf "$archive" .
  log "backup done. Keep $DATA_DIR/.env with these files: a restore needs its AUTH_SECRET and ENCRYPTION_SECRET."
}

cmd_update() {
  # Pull first: if the registry is unreachable, stop before a backup is taken and before containers change.
  require_running_stack
  pull_image "$APP_IMAGE"
  cmd_backup
  cmd_up
}

main() {
  local command="${1:-up}"
  APP_IMAGE="$(resolve_app_image)"
  [ -n "$APP_IMAGE" ] || die "$APP_IMAGE_STAMP is empty; set RR_IMAGE or delete the file"
  if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$command" != "logs" ]; }; then
    usage >&2
    exit 2
  fi
  case "$command" in
    up) cmd_up ;;
    down) cmd_down ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs "${2:-}" ;;
    backup) cmd_backup ;;
    update) cmd_update ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
