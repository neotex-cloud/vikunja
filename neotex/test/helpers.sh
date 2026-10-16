# Shared helpers for neotex/test/*_test.sh. Sourced by neotex/test/run.

assert_eq() {
  local expected=$1 actual=$2 msg=${3:-}
  if [ "$expected" != "$actual" ]; then
    printf 'assert_eq failed%s\n  expected: [%s]\n  actual:   [%s]\n' "${msg:+ ($msg)}" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack=$1 needle=$2
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'assert_contains failed\n  needle:   [%s]\n  haystack: [%s]\n' "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'assert_not_contains failed\n  needle:   [%s]\n  haystack: [%s]\n' "$needle" "$haystack" >&2
    exit 1
  fi
}

# commit_file <file> <content> <message>: write, stage and commit in the cwd repo.
commit_file() {
  printf '%s\n' "$2" > "$1"
  git add "$1"
  git commit -q -m "$3"
}

# make_upstream_repo <dir>: a repo shaped like upstream's tag history —
# v2.4.0, v2.5.0-rc1, v2.5.0, v2.6.0 on main, and v2.5.1 on a branch off v2.5.0.
make_upstream_repo() {
  local dir=$1
  git init -q -b main "$dir"
  (
    cd "$dir"
    commit_file a.txt "a 2.4.0" "release 2.4.0" && git tag v2.4.0
    commit_file a.txt "a 2.5.0-rc1" "release 2.5.0-rc1" && git tag v2.5.0-rc1
    commit_file a.txt "a 2.5.0" "release 2.5.0" && git tag v2.5.0
    commit_file a.txt "a 2.6.0" "release 2.6.0" && git tag v2.6.0
    git switch -q -c release-2.5 v2.5.0
    commit_file a.txt "a 2.5.1" "release 2.5.1" && git tag v2.5.1
    git switch -q main
  )
}

# fake_cmd <name> <body>: put a stub <name> first on PATH. Every call is
# appended to $FAKE_LOG as "<name> <args>" before <body> runs.
fake_cmd() {
  local name=$1 body=$2
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"$name \$*\" >> \"\$FAKE_LOG\""
    printf '%s\n' "$body"
  } > "$FAKE_BIN/$name"
  chmod +x "$FAKE_BIN/$name"
}
