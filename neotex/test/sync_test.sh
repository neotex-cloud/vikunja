# sync_setup: upstream repo `up` (tags v2.4.0..v2.6.0), a bare `origin.git`
# where main = v2.4.0 and fork = v2.4.0 + one commit of ours, and a clone
# `work` of it, where the test runs. gh is faked: no open PR, no workflows.
sync_setup() {
  make_upstream_repo up
  git init -q --bare -b fork origin.git
  (
    cd up
    git switch -q -c ours v2.4.0
    commit_file b.txt "ours" "ours: change"
    git push -q ../origin.git v2.4.0^{commit}:refs/heads/main ours:refs/heads/fork
    git switch -q main
  )
  git clone -q origin.git work
  cd work
  export UPSTREAM_URL="$PWD/../up"
  fake_cmd gh '
case "$1 $2" in
  "workflow list") echo "[]" ;;
  "pr create") echo "https://github.com/neotex-cloud/vikunja/pull/7" ;;
esac'
}

remote_sha() {
  git ls-remote origin "refs/heads/$1" | cut -f1
}

test_sync_opens_upgrade_pr_to_newest_release() {
  sync_setup
  out=$(sync-upstream)
  assert_eq "$(git rev-parse 'v2.6.0^{commit}')" "$(remote_sha main)" "main moved to the release"
  assert_eq "$(git rev-parse v2.6.0)" "$(git ls-remote origin refs/tags/v2.6.0 | cut -f1)" "release tag pushed"
  git fetch -q origin upgrade/v2.6.0
  assert_eq 1 "$(git rev-list --count v2.6.0..FETCH_HEAD)" "our commit on top of v2.6.0"
  assert_eq "ours" "$(git show FETCH_HEAD:b.txt)"
  log=$(cat "$FAKE_LOG")
  assert_contains "$log" "gh pr create --base main --head upgrade/v2.6.0 --title Upgrade to Vikunja v2.6.0"
  assert_contains "$log" "fork-base=$(remote_sha fork)"
  assert_not_contains "$log" "--draft"
  assert_contains "$out" "https://github.com/neotex-cloud/vikunja/pull/7"
  assert_eq "fork" "$(git branch --show-current)" "caller's checkout untouched"
  assert_eq "$(remote_sha fork)" "$(git rev-parse HEAD)"
}

test_sync_to_named_release() {
  sync_setup
  sync-upstream v2.5.0 >/dev/null
  assert_eq "$(git rev-parse 'v2.5.0^{commit}')" "$(remote_sha main)"
  assert_contains "$(cat "$FAKE_LOG")" "--head upgrade/v2.5.0"
}

test_sync_nothing_newer() {
  sync_setup
  (cd ../up && git push -q ../origin.git v2.6.0^{commit}:refs/heads/main v2.6.0^{commit}:refs/heads/fork --force)
  out=$(sync-upstream)
  assert_contains "$out" "fork is on v2.6.0; nothing newer upstream"
  assert_not_contains "$(cat "$FAKE_LOG")" "gh pr create"
}

test_sync_conflict_opens_draft() {
  sync_setup
  (
    cd ../up
    git switch -q main
    commit_file b.txt "upstream" "upstream: add b.txt" && git tag v2.7.0
  )
  rc=0
  out=$(sync-upstream) || rc=$?
  assert_eq 0 "$rc"
  log=$(cat "$FAKE_LOG")
  assert_contains "$log" "--head upgrade/v2.7.0"
  assert_contains "$log" "--draft"
  assert_contains "$log" "Rebase stopped on a conflict"
}

test_sync_updates_existing_pr() {
  sync_setup
  fake_cmd gh '
case "$1 $2" in
  "workflow list") echo "[]" ;;
  "pr list") echo 5 ;;
esac'
  sync-upstream >/dev/null
  log=$(cat "$FAKE_LOG")
  assert_contains "$log" "gh pr edit 5 --body"
  assert_not_contains "$log" "gh pr create"
}

test_sync_disables_upstream_workflows() {
  sync_setup
  fake_cmd gh '
case "$1 $2" in
  "workflow list") echo "[{\"id\":9,\"path\":\".github/workflows/ci.yml\",\"state\":\"active\"}]" ;;
esac'
  sync-upstream >/dev/null
  assert_contains "$(cat "$FAKE_LOG")" "gh workflow disable 9"
}

test_sync_pushes_tag_when_main_already_there() {
  sync_setup
  (cd ../up && git push -q ../origin.git v2.6.0^{commit}:refs/heads/main --force)
  sync-upstream >/dev/null
  assert_eq "$(git rev-parse v2.6.0)" "$(git ls-remote origin refs/tags/v2.6.0 | cut -f1)"
}
