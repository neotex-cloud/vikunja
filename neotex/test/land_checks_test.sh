# Fixtures for land-checks: files in the cwd that the fake gh serves.
HEAD_SHA=1111111111111111111111111111111111111111
FORK_BASE=2222222222222222222222222222222222222222
OLD_SHA=3333333333333333333333333333333333333333

# land_fixtures [<draft>] [<state>] [<body>]: an upgrade PR that is ready to land.
land_fixtures() {
  local draft=${1:-false} state=${2:-open}
  local body=${3:-"<!-- neotex-upgrade from=v2.4.0 to=v2.7.0 fork-base=$FORK_BASE -->"}
  jq -n --arg head "$HEAD_SHA" --arg body "$body" --argjson draft "$draft" --arg state "$state" '{
    number: 7, state: $state, draft: $draft, body: $body,
    base: {ref: "main"},
    head: {ref: "upgrade/v2.7.0", sha: $head, repo: {full_name: "neotex-cloud/vikunja"}}
  }' > pr.json
  jq -n --arg head "$HEAD_SHA" '[{user: {login: "turner"}, state: "APPROVED", commit_id: $head}]' > reviews.json
  jq -n '{check_runs: [
    {name: "scripts", status: "completed", conclusion: "success"},
    {name: "upstream / mage", status: "completed", conclusion: "success"},
    {name: "image", status: "completed", conclusion: "success"},
    {name: "land-trigger", status: "in_progress", conclusion: null}
  ]}' > checks.json
  echo write > perm_turner
  export GITHUB_REPOSITORY=neotex-cloud/vikunja
  fake_cmd gh '
path=$2
case "$path" in
  repos/neotex-cloud/vikunja/pulls/7) cat pr.json ;;
  repos/neotex-cloud/vikunja/pulls/7/reviews*) cat reviews.json ;;
  repos/neotex-cloud/vikunja/collaborators/*/permission)
    user=${path#repos/neotex-cloud/vikunja/collaborators/}; user=${user%/permission}
    if [ -f "perm_$user" ]; then jq -n --arg p "$(cat "perm_$user")" "{permission: \$p}"; else echo "Not Found" >&2; exit 1; fi ;;
  repos/neotex-cloud/vikunja/commits/*/check-runs*) cat checks.json ;;
  *) echo "unexpected gh $*" >&2; exit 9 ;;
esac'
}

# expect_refusal <needle>: land-checks 7 must exit 1 with <needle> on stderr.
expect_refusal() {
  local rc=0 err
  err=$(land-checks 7 2>&1 >/dev/null) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$err" "$1"
}

test_land_checks_passes_writer_approval_on_head() {
  land_fixtures
  assert_eq "$HEAD_SHA $FORK_BASE" "$(land-checks 7)"
}

test_land_checks_rejects_approval_by_non_collaborator() {
  land_fixtures
  jq -n --arg head "$HEAD_SHA" '[{user: {login: "stranger"}, state: "APPROVED", commit_id: $head}]' > reviews.json
  expect_refusal "no approval of $HEAD_SHA by someone with write access"
}

test_land_checks_rejects_approval_by_read_only_collaborator() {
  land_fixtures
  echo read > perm_turner
  expect_refusal "no approval of $HEAD_SHA by someone with write access"
}

test_land_checks_rejects_approval_of_older_commit() {
  land_fixtures
  jq -n --arg old "$OLD_SHA" '[{user: {login: "turner"}, state: "APPROVED", commit_id: $old}]' > reviews.json
  expect_refusal "no approval of $HEAD_SHA by someone with write access"
}

test_land_checks_uses_each_reviewers_latest_review() {
  land_fixtures
  jq -n --arg head "$HEAD_SHA" '[
    {user: {login: "turner"}, state: "APPROVED", commit_id: $head},
    {user: {login: "turner"}, state: "CHANGES_REQUESTED", commit_id: $head}
  ]' > reviews.json
  expect_refusal "changes requested by turner"
}

test_land_checks_ignores_comment_after_approval() {
  land_fixtures
  jq -n --arg head "$HEAD_SHA" '[
    {user: {login: "turner"}, state: "APPROVED", commit_id: $head},
    {user: {login: "turner"}, state: "COMMENTED", commit_id: $head}
  ]' > reviews.json
  assert_eq "$HEAD_SHA $FORK_BASE" "$(land-checks 7)"
}

test_land_checks_rejects_draft() {
  land_fixtures true
  expect_refusal "the PR is a draft"
}

test_land_checks_rejects_closed_pr() {
  land_fixtures false closed
  expect_refusal "the PR is closed"
}

test_land_checks_rejects_failed_check() {
  land_fixtures
  jq '.check_runs[1].conclusion = "failure"' checks.json > c && mv c checks.json
  expect_refusal "checks not green: upstream / mage"
}

test_land_checks_rejects_running_check() {
  land_fixtures
  jq '.check_runs[2].status = "in_progress" | .check_runs[2].conclusion = null' checks.json > c && mv c checks.json
  expect_refusal "checks still running: image"
}

test_land_checks_rejects_no_checks() {
  land_fixtures
  jq -n '{check_runs: [{name: "land-trigger", status: "completed", conclusion: "success"}]}' > checks.json
  expect_refusal "no CI checks have run on $HEAD_SHA"
}

test_land_checks_rejects_missing_marker() {
  land_fixtures false open "Upgrade to Vikunja v2.7.0"
  expect_refusal "no neotex-upgrade marker"
}
