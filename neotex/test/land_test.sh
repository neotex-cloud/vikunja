# land_setup: upstream repo `up` with a bare `origin.git` where main = v2.5.0
# and fork = v2.4.0 + one commit of ours; `up` gets that commit rebased onto
# v2.5.0 as branch `upgrade`. Leaves the cwd in `up`.
land_setup() {
  make_upstream_repo up
  git init -q --bare origin.git
  cd up
  git remote add origin ../origin.git
  git switch -q -c fork v2.4.0
  commit_file b.txt "ours" "ours: change"
  git push -q origin v2.5.0^{commit}:refs/heads/main fork:refs/heads/fork
  git switch -q main
  rebase-fork v2.5.0 v2.4.0 fork upgrade >/dev/null
}

test_land_moves_fork() {
  land_setup
  expected=$(git rev-parse fork)
  head=$(git rev-parse upgrade)
  land-upgrade origin "$head" "$expected"
  assert_eq "$head" "$(git ls-remote origin refs/heads/fork | cut -f1)"
}

test_land_refuses_when_fork_moved() {
  land_setup
  expected=$(git rev-parse fork)
  head=$(git rev-parse upgrade)
  git clone -q ../origin.git ../other
  (cd ../other && git switch -q fork && commit_file e.txt new "ours: landed meanwhile" && git push -q origin fork)
  moved=$(git ls-remote origin refs/heads/fork | cut -f1)

  rc=0
  out=$(land-upgrade origin "$head" "$expected" 2>&1) || rc=$?
  assert_eq 5 "$rc"
  assert_contains "$out" "fork moved since this upgrade was built; re-run neotex/bin/sync-upstream"
  assert_eq "$moved" "$(git ls-remote origin refs/heads/fork | cut -f1)"
}

test_land_refuses_head_not_on_main() {
  land_setup
  expected=$(git rev-parse fork)
  rc=0
  out=$(land-upgrade origin "$expected" "$expected" 2>&1) || rc=$?
  assert_eq 4 "$rc"
  assert_contains "$out" "head does not build on main"
  assert_eq "$expected" "$(git ls-remote origin refs/heads/fork | cut -f1)"
}

# land_pr_setup: land_setup, plus the upgrade branch pushed as
# upgrade/v2.5.0, a clone `work` of origin (where the test runs), and a fake
# gh whose `pr view` prints pr.json (an open, ready upgrade PR built from fork).
land_pr_setup() {
  land_setup
  git push -q origin upgrade:refs/heads/upgrade/v2.5.0
  fork_base=$(git rev-parse fork)
  head=$(git rev-parse upgrade)
  cd ..
  git clone -q origin.git work
  cd work
  write_pr_json false "<!-- neotex-upgrade from=v2.4.0 to=v2.5.0 fork-base=$fork_base -->"
  fake_cmd gh '
case "$1 $2" in
  "pr view") cat "$FAKE_BIN/../pr.json" ;;
  "workflow list") echo "[]" ;;
esac'
}

# write_pr_json <draft> <first body line>
write_pr_json() {
  jq -n --arg head "$head" --argjson draft "$1" --arg body "$2"$'\n\nbody' '{
    state: "OPEN", isDraft: $draft, baseRefName: "main",
    headRefName: "upgrade/v2.5.0", headRefOid: $head, body: $body}' > "$FAKE_BIN/../pr.json"
}

test_land_pr_moves_fork_and_closes() {
  land_pr_setup
  out=$(land-pr 12)
  assert_eq "$head" "$(git ls-remote origin refs/heads/fork | cut -f1)"
  assert_contains "$(cat "$FAKE_LOG")" "gh pr close 12 --comment Landed on fork at $head"
  assert_contains "$out" "landed $head on fork"
}

test_land_pr_refuses_draft() {
  land_pr_setup
  write_pr_json true "<!-- neotex-upgrade from=v2.4.0 to=v2.5.0 fork-base=$fork_base -->"
  rc=0
  out=$(land-pr 12 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "draft"
  assert_eq "$fork_base" "$(git ls-remote origin refs/heads/fork | cut -f1)"
  assert_not_contains "$(cat "$FAKE_LOG")" "gh pr close"
}

test_land_pr_refuses_without_marker() {
  land_pr_setup
  write_pr_json false "an upgrade"
  rc=0
  out=$(land-pr 12 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no neotex-upgrade marker"
  assert_eq "$fork_base" "$(git ls-remote origin refs/heads/fork | cut -f1)"
}

test_land_pr_leaves_pr_open_when_fork_moved() {
  land_pr_setup
  git switch -q fork
  commit_file e.txt new "ours: landed meanwhile"
  git push -q origin fork
  rc=0
  out=$(land-pr 12 2>&1) || rc=$?
  assert_eq 5 "$rc"
  assert_contains "$out" "re-run neotex/bin/sync-upstream"
  assert_not_contains "$(cat "$FAKE_LOG")" "gh pr close"
}
