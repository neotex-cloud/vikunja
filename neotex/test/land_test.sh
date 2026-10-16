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
  assert_contains "$out" "fork moved since this upgrade was built; re-run the upstream sync"
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
