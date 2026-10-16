# fake_aws <instances> [<invocation-json>]: stub aws for a deploy run.
# <instances> is what describe-instances prints; the SSM invocation result
# defaults to Success.
fake_aws() {
  local invocation=${2:-'{"Status":"Success","StandardErrorContent":""}'}
  fake_cmd aws "
case \"\$1 \$2\" in
  'ec2 describe-instances') echo '$1' ;;
  'ec2 describe-volumes') echo vol-0data ;;
  'ec2 create-snapshot') echo snap-0123 ;;
  'ec2 describe-snapshots') echo completed ;;
  'ssm send-command') echo cmd-1 ;;
  'ssm get-command-invocation') echo '$invocation' ;;
  'ssm put-parameter') echo '{\"Version\":2}' ;;
  *) echo \"unexpected aws call: \$*\" >&2; exit 9 ;;
esac"
}

deploy_env() {
  export POLL_INTERVAL=0 DEPLOY_TIMEOUT=1 SNAPSHOT_TIMEOUT=1
}

# line_of <pattern>: line number of the first $FAKE_LOG line matching it.
line_of() {
  grep -n -- "$1" "$FAKE_LOG" | head -n 1 | cut -d: -f1
}

test_deploy_happy_path() {
  deploy_env
  fake_aws i-0box
  fake_cmd curl 'echo "{\"version\":\"v2.4.0-neotex.3\"}"'
  out=$(deploy 2.4.0-neotex.3)
  assert_contains "$out" "SNAPSHOT snap-0123"
  snap=$(line_of 'aws ec2 create-snapshot')
  send=$(line_of 'aws ssm send-command')
  put=$(line_of 'aws ssm put-parameter')
  [ -n "$snap" ] && [ -n "$send" ] && [ -n "$put" ] || { cat "$FAKE_LOG" >&2; exit 1; }
  [ "$snap" -lt "$send" ] && [ "$send" -lt "$put" ] || { echo "wrong order: $snap $send $put" >&2; exit 1; }
  assert_contains "$(grep 'aws ssm put-parameter' "$FAKE_LOG")" "--name /vikunja/image"
  assert_contains "$(grep 'aws ssm put-parameter' "$FAKE_LOG")" "--value ghcr.io/neotex-cloud/vikunja:2.4.0-neotex.3"
  assert_contains "$(grep 'aws ssm send-command' "$FAKE_LOG")" "--instance-ids i-0box"
}

test_deploy_fails_on_version_mismatch() {
  deploy_env
  fake_aws i-0box
  fake_cmd curl 'echo "{\"version\":\"v2.4.0\"}"'
  rc=0
  out=$(deploy 2.4.0-neotex.3 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "version never reached v2.4.0-neotex.3; restore point: SNAPSHOT snap-0123"
  assert_not_contains "$(cat "$FAKE_LOG")" "put-parameter"
}

test_deploy_refuses_two_instances() {
  deploy_env
  fake_aws "i-0one	i-0two"
  fake_cmd curl 'echo "{\"version\":\"v2.4.0-neotex.3\"}"'
  rc=0
  out=$(deploy 2.4.0-neotex.3 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "expected exactly one running vikunja instance"
  assert_not_contains "$(cat "$FAKE_LOG")" "create-snapshot"
}

test_deploy_fails_when_ssm_command_fails() {
  deploy_env
  fake_aws i-0box '{"Status":"Failed","StandardErrorContent":"pull access denied"}'
  fake_cmd curl 'echo "{\"version\":\"v2.4.0-neotex.3\"}"'
  rc=0
  out=$(deploy 2.4.0-neotex.3 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "pull access denied"
  assert_contains "$out" "SNAPSHOT snap-0123"
  assert_not_contains "$(cat "$FAKE_LOG")" "put-parameter"
}

test_swap_image_only_touches_vikunja() {
  mkdir data
  cat > data/docker-compose.yml <<'YAML'
services:
  vikunja:
    image: vikunja/vikunja:2.4.0
    restart: unless-stopped
    environment:
      VIKUNJA_DATABASE_HOST: "db"
  db:
    image: postgres:16
    restart: unless-stopped
YAML
  fake_cmd docker 'exit 0'
  IMAGE=ghcr.io/neotex-cloud/vikunja:2.4.0-neotex.3 COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" \
    bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh"
  compose=$(cat data/docker-compose.yml)
  assert_eq 1 "$(grep -c 'image: ghcr.io/neotex-cloud/vikunja:2.4.0-neotex.3' data/docker-compose.yml)"
  assert_contains "$compose" "    image: postgres:16"
  assert_not_contains "$compose" "vikunja/vikunja:2.4.0"
  assert_contains "$(cat "$FAKE_LOG")" "pull vikunja"
  assert_contains "$(cat "$FAKE_LOG")" "up -d"
}

test_swap_image_refuses_when_no_vikunja_image_line() {
  mkdir data
  printf 'services:\n  db:\n    image: postgres:16\n' > data/docker-compose.yml
  fake_cmd docker 'exit 0'
  rc=0
  err=$(IMAGE=x COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected failure" >&2; exit 1; }
  assert_contains "$err" "no image line for the vikunja service"
  assert_eq "$(printf 'services:\n  db:\n    image: postgres:16')" "$(cat data/docker-compose.yml)"
  assert_eq "" "$(cat "$FAKE_LOG")" "docker never called"
}
