# fork_with_two_commits: in the cwd upstream repo, branch `fork` off v2.4.0
# with two commits that edit b.txt.
fork_with_two_commits() {
  git switch -q -c fork v2.4.0
  commit_file b.txt "ours 1" "ours: first"
  commit_file b.txt "ours 2" "ours: second"
  git switch -q main
}

test_rebase_clean() {
  make_upstream_repo up && cd up
  fork_with_two_commits
  rebase-fork v2.5.0 v2.4.0 fork out
  assert_eq 2 "$(git rev-list --count v2.5.0..out)"
  assert_eq "ours 2" "$(git show out:b.txt)"
  assert_eq "a 2.5.0" "$(git show out:a.txt)"
  assert_eq "ours: first" "$(git log -1 --format=%s out~1)"
  assert_eq "main" "$(git branch --show-current)" "caller's branch untouched"
}

test_rebase_conflict_reports_commit() {
  git init -q -b main up && cd up
  printf 'line1\nline2\n' > b.txt && git add b.txt && git commit -q -m base && git tag v2.4.0
  git switch -q -c fork v2.4.0
  commit_file c.txt "ours" "ours: unrelated"
  printf 'ours line1\nline2\n' > b.txt && git commit -q -am "ours: touch line1"
  stopped=$(git rev-parse HEAD)
  git switch -q main
  printf 'upstream line1\nline2\n' > b.txt && git commit -q -am "upstream: touch line1" && git tag v2.5.0

  rc=0
  out=$(rebase-fork v2.5.0 v2.4.0 fork out) || rc=$?
  assert_eq 3 "$rc"
  assert_eq "CONFLICT $stopped ours: touch line1" "$out"
  assert_eq 1 "$(git rev-list --count v2.5.0..out)"
  assert_eq "ours" "$(git show out:c.txt)"
  assert_eq "main" "$(git branch --show-current)"
  assert_eq "" "$(git status --porcelain)" "no rebase left in progress"
}

test_rebase_includes_new_fork_commit() {
  make_upstream_repo up && cd up
  fork_with_two_commits
  rebase-fork v2.5.0 v2.4.0 fork out
  git switch -q fork
  commit_file d.txt "ours 3" "ours: third"
  git switch -q main
  rebase-fork v2.5.0 v2.4.0 fork out
  assert_eq 3 "$(git rev-list --count v2.5.0..out)"
  assert_eq "ours 3" "$(git show out:d.txt)"
}

test_rebase_bad_args() {
  rc=0
  rebase-fork 2>/dev/null || rc=$?
  assert_eq 2 "$rc"
}
