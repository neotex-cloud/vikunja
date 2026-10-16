test_disable_upstream_workflows_disables_only_foreign() {
  fake_cmd gh '
if [ "$1 $2" = "workflow list" ]; then
  cat <<JSON
[{"id":1,"path":".github/workflows/ci.yml","state":"active"},
 {"id":2,"path":".github/workflows/test.yml","state":"active"},
 {"id":3,"path":".github/workflows/neotex-ci.yml","state":"active"},
 {"id":4,"path":".github/workflows/new-upstream.yml","state":"active"},
 {"id":5,"path":".github/workflows/crowdin.yml","state":"disabled_manually"}]
JSON
fi'
  out=$(disable-upstream-workflows)
  log=$(cat "$FAKE_LOG")
  assert_contains "$log" "gh workflow disable 1"
  assert_contains "$log" "gh workflow disable 4"
  assert_not_contains "$log" "gh workflow disable 2"
  assert_not_contains "$log" "gh workflow disable 3"
  assert_not_contains "$log" "gh workflow disable 5"
  assert_contains "$out" "disabled .github/workflows/ci.yml"
  assert_contains "$out" "disabled .github/workflows/new-upstream.yml"
}
