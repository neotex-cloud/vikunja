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
