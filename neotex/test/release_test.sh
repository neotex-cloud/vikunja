test_next_release_picks_newest_stable() {
  make_upstream_repo up && cd up
  assert_eq "v2.6.0" "$(next-release v2.4.0)"
}

test_next_release_ignores_prerelease_and_older() {
  make_upstream_repo up && cd up
  assert_eq "v2.6.0" "$(next-release v2.5.0)" "v2.5.1 loses to v2.6.0"
  assert_eq "" "$(next-release v2.6.0)" "v2.5.1 is older than v2.6.0"
  git tag v2.7.0-rc1
  assert_eq "" "$(next-release v2.6.0)" "prerelease ignored"
}

test_image_tag_counts_commits_since_tag() {
  make_upstream_repo up && cd up
  git switch -q -c fork v2.4.0
  commit_file b.txt one "ours 1"
  commit_file b.txt two "ours 2"
  commit_file b.txt three "ours 3"
  assert_eq "2.4.0-neotex.3" "$(image-tag)"
}

test_image_tag_skips_prerelease_tags() {
  make_upstream_repo up && cd up
  git switch -q -c fork v2.4.0
  commit_file b.txt one "ours 1"
  commit_file b.txt two "ours 2" && git tag v2.4.1-rc1
  commit_file b.txt three "ours 3"
  assert_eq "2.4.0-neotex.3" "$(image-tag)"
}

test_image_tag_fails_without_tag() {
  git init -q -b main norepo && cd norepo
  commit_file x.txt x "untagged"
  rc=0
  err=$(image-tag 2>&1 >/dev/null) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$err" "no upstream release tag"
}

test_pr_body_marker_and_links() {
  make_upstream_repo up && cd up
  base=$(git rev-parse v2.4.0)
  body=$(upgrade-pr-body v2.4.0 v2.6.0 "$base")
  assert_eq "<!-- neotex-upgrade from=v2.4.0 to=v2.6.0 fork-base=$base -->" "$(head -n 1 <<<"$body")"
  assert_contains "$body" "https://github.com/go-vikunja/vikunja/releases/tag/v2.5.0"
  assert_contains "$body" "https://github.com/go-vikunja/vikunja/releases/tag/v2.6.0"
  assert_not_contains "$body" "releases/tag/v2.5.0-rc1"
  assert_not_contains "$body" "releases/tag/v2.4.0"
  assert_not_contains "$body" "releases/tag/v2.5.1"
}

test_pr_body_lists_new_workflows() {
  make_upstream_repo up && cd up
  git switch -q main
  mkdir -p .github/workflows
  commit_file .github/workflows/new.yml "on: push" "upstream adds a workflow"
  git tag v2.7.0
  body=$(upgrade-pr-body v2.6.0 v2.7.0 "$(git rev-parse v2.4.0)")
  assert_contains "$body" ".github/workflows/new.yml"
}

test_pr_body_no_new_workflows_says_none() {
  make_upstream_repo up && cd up
  body=$(upgrade-pr-body v2.4.0 v2.6.0 "$(git rev-parse v2.4.0)")
  assert_contains "$body" "New upstream workflows: none"
}

test_pr_body_conflict_instructions() {
  make_upstream_repo up && cd up
  git switch -q -c fork v2.4.0
  commit_file b.txt one "ours 1"
  stopped=$(git rev-parse HEAD)
  commit_file b.txt two "ours 2"
  after=$(git rev-parse HEAD)
  body=$(upgrade-pr-body v2.4.0 v2.6.0 "$after" "CONFLICT $stopped ours 1")
  assert_contains "$body" "$stopped"
  assert_contains "$body" "git cherry-pick $stopped $after"
  assert_contains "$body" "git push --force-with-lease origin upgrade/v2.6.0"
  assert_contains "$body" "mark ready for review"
}
