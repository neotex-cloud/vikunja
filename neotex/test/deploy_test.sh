# fake_aws <instances> [<invocation-json>]: stub aws for a deploy run.
# <instances> is what describe-instances prints; the SSM invocation result
# defaults to Success.
fake_aws() {
  local invocation=${2:-'{"Status":"Success","StandardErrorContent":""}'}
  fake_cmd aws "
case \"\$1 \$2\" in
  'sts get-caller-identity') echo 123456789012 ;;
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
  assert_contains "$(grep 'aws ssm put-parameter' "$FAKE_LOG")" "--value 123456789012.dkr.ecr.us-east-2.amazonaws.com/neotex-cloud/vikunja:2.4.0-neotex.3"
  assert_contains "$(grep 'aws ssm send-command' "$FAKE_LOG")" "--instance-ids i-0box"
  assert_contains "$(cat "$FAKE_LOG")" "export IMAGE='123456789012.dkr.ecr.us-east-2.amazonaws.com/neotex-cloud/vikunja:2.4.0-neotex.3'"
}

test_deploy_honours_image_repo_override() {
  deploy_env
  fake_aws i-0box
  fake_cmd curl 'echo "{\"version\":\"v2.4.0-neotex.3\"}"'
  IMAGE_REPO=registry.example/vikunja deploy 2.4.0-neotex.3 > /dev/null
  assert_contains "$(grep 'aws ssm put-parameter' "$FAKE_LOG")" "--value registry.example/vikunja:2.4.0-neotex.3"
  assert_not_contains "$(cat "$FAKE_LOG")" "get-caller-identity"
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
  fake_cmd docker 'if [ "$1" = login ]; then cat > /dev/null; fi'
  fake_cmd aws 'echo ecr-token'
  IMAGE=$ECR_IMAGE COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" \
    bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh"
  compose=$(cat data/docker-compose.yml)
  assert_eq 1 "$(grep -c "image: $ECR_IMAGE" data/docker-compose.yml)"
  assert_contains "$compose" "    image: postgres:16"
  assert_not_contains "$compose" "vikunja/vikunja:2.4.0"
  assert_contains "$(cat "$FAKE_LOG")" "docker pull $ECR_IMAGE"
  assert_contains "$(cat "$FAKE_LOG")" "up -d"
}

ECR_IMAGE=123456789012.dkr.ecr.us-east-2.amazonaws.com/neotex-cloud/vikunja:2.4.0-neotex.3

# The box's instance role is the only credential: the swap fetches an ECR
# token with it and hands it to docker on stdin, before the pull.
test_swap_image_logs_in_to_ecr_before_pull() {
  mkdir data
  printf 'services:\n  vikunja:\n    image: vikunja/vikunja:2.4.0\n' > data/docker-compose.yml
  fake_cmd aws 'echo ecr-token'
  fake_cmd docker 'if [ "$1" = login ]; then cat > "$FAKE_BIN/login-stdin"; fi'
  IMAGE=$ECR_IMAGE COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" \
    bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh"
  assert_contains "$(cat "$FAKE_LOG")" "aws ecr get-login-password --region us-east-2"
  assert_contains "$(cat "$FAKE_LOG")" "docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-2.amazonaws.com"
  assert_eq "ecr-token" "$(cat "$FAKE_BIN/login-stdin")" "token passed on stdin"
  login=$(line_of 'docker login')
  pull=$(line_of 'docker pull')
  [ "$login" -lt "$pull" ] || { echo "login ($login) must precede pull ($pull)" >&2; exit 1; }
}

test_swap_image_failed_ecr_login_leaves_compose_alone() {
  mkdir data
  printf 'services:\n  vikunja:\n    image: vikunja/vikunja:2.4.0\n' > data/docker-compose.yml
  before=$(cat data/docker-compose.yml)
  fake_cmd aws 'echo "AccessDenied" >&2; exit 254'
  fake_cmd docker 'exit 0'
  rc=0
  err=$(IMAGE=$ECR_IMAGE COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" \
    bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected failure" >&2; exit 1; }
  assert_contains "$err" "could not log in to 123456789012.dkr.ecr.us-east-2.amazonaws.com"
  assert_eq "$before" "$(cat data/docker-compose.yml)" "compose untouched when the login fails"
  assert_not_contains "$(cat "$FAKE_LOG")" "docker pull"
}

test_swap_image_skips_login_for_other_registries() {
  mkdir data
  printf 'services:\n  vikunja:\n    image: vikunja/vikunja:2.4.0\n' > data/docker-compose.yml
  fake_cmd aws 'exit 0'
  fake_cmd docker 'exit 0'
  IMAGE=vikunja/vikunja:2.7.0 COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" \
    bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh"
  assert_not_contains "$(cat "$FAKE_LOG")" "aws "
  assert_not_contains "$(cat "$FAKE_LOG")" "docker login"
  assert_contains "$(cat "$FAKE_LOG")" "docker pull vikunja/vikunja:2.7.0"
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

test_swap_image_failed_pull_leaves_compose_alone() {
  mkdir data
  printf 'services:\n  vikunja:\n    image: vikunja/vikunja:2.4.0\n  db:\n    image: postgres:16\n' > data/docker-compose.yml
  before=$(cat data/docker-compose.yml)
  fake_cmd docker 'if [ "$1" = pull ]; then echo "manifest unknown" >&2; exit 1; fi'
  rc=0
  IMAGE=ghcr.io/neotex-cloud/vikunja:missing COMPOSE_FILE_PATH="$PWD/data/docker-compose.yml" \
    bash "$NEOTEX_ROOT/neotex/bin/remote-swap-image.sh" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected failure" >&2; exit 1; }
  assert_eq "$before" "$(cat data/docker-compose.yml)" "compose untouched when the pull fails"
  assert_not_contains "$(cat "$FAKE_LOG")" "up -d"
}
