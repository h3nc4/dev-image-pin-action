#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Walks pin.sh, bump.sh and release.sh through a throwaway repository and its bare remote, with
# docker replaced by a stub that plays the registry. Needs git alone.

set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT INT TERM
remote="${work}/remote.git"
repo="${work}/repo"
failures=0

ok() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  shift
  for line in "$@"; do printf '          %s\n' "${line}"; done
  failures=$((failures + 1))
}

expect() { # $1=label $2=expected, rest: command printing the actual value
  label="$1"
  expected="$2"
  shift 2
  actual="$("$@")" || actual="(exited $?)"
  if [ "${expected}" = "${actual}" ]; then ok "${label}"; else fail "${label}" "expected ${expected}" "got      ${actual}"; fi
}

expect_log() { # $1=label $2=fragment the last run's log has to carry
  if grep -qF -- "$2" "${work}/log"; then
    ok "$1"
    return 0
  fi
  log="$(cat "${work}/log")"
  fail "$1" "no mention of '${2}' in:" "${log}"
}

pin() { printf '{\n  // "image": "old/commented:1",\n  "image": "%s"\n}\n' "$1" >.devcontainer.json; }

output() { sed -n "s/^$1=//p" "${work}/out"; }

outcome() { # prints the last run's exit status, then each named output
  line="${status}"
  for key in "$@"; do
    value="$(output "${key}")"
    line="${line} ${value}"
  done
  printf '%s\n' "${line}"
}

pinned() { # $1=remote object holding a dev container definition, rest: pin.sh flags
  object="$1"
  shift
  git --git-dir="${remote}" show "${object}" | "${root}/pin.sh" "$@" -
}

calls() { tr '\n' ' ' <"${work}/docker.log" | sed 's/ $//'; }

called() { grep -c -x -F -- "$1" "${work}/docker.log" || true; }

run() { # $1=script, rest: VAR=value overrides. Sets status to the script's exit code.
  script="$1"
  shift
  : >"${work}/out"
  : >"${work}/docker.log"
  status=0
  env - PATH="${PATH}" HOME="${work}" \
    GITHUB_WORKSPACE="${repo}" GITHUB_OUTPUT="${work}/out" \
    DOCKER="${work}/docker" STUB_DIR="${work}" \
    AUTHOR_NAME=ci AUTHOR_EMAIL=ci@example.com \
    "$@" sh "${root}/${script}" >"${work}/log" 2>&1 || status=$?
}

# Plays the registry from a file of pushed refs, and fails a manifest read for a ref in refused.
# An absent ref answers as Docker Hub does, or with the text in missing, as Forgejo's registry does.
cat >"${work}/docker" <<'STUB'
#!/bin/sh
work="${STUB_DIR:?}"
case "$1" in
  manifest)
    if grep -qxF -- "$3" "${work}/refused"; then
      echo "unauthorized: authentication required" >&2
      exit 1
    fi
    grep -qxF -- "$3" "${work}/registry" && exit 0
    if [ -s "${work}/missing" ]; then
      cat "${work}/missing" >&2
    else
      echo "no such manifest: docker.io/$3" >&2
    fi
    exit 1
    ;;
  push)
    if grep -qxF -- "$2" "${work}/limited"; then
      grep -vxF -- "$2" "${work}/limited" >"${work}/limited.next" || true
      mv "${work}/limited.next" "${work}/limited"
      echo "unexpected status from POST request to https://registry/v2/token: 429 Too Many Requests" >&2
      exit 1
    fi
    echo "$2" >>"${work}/registry"
    ;;
  *) ;;
esac
echo "$*" >>"${work}/docker.log"
STUB
chmod +x "${work}/docker"
: >"${work}/registry"
: >"${work}/refused"
: >"${work}/missing"
: >"${work}/limited"
git init -q --bare -b main "${remote}"
git init -q -b main "${repo}"
cd "${repo}"
git config user.email ci@example.com
git config user.name CI
git config commit.gpgsign false
git remote add origin "${remote}"
mkdir -p docker scripts
pin h3nc4/app-dev:7
printf 'FROM busybox\n' >docker/dev.Dockerfile
printf 'FROM busybox\n' >docker/ci.Dockerfile
printf 'unrelated\n' >README.md
git add -A
git commit -qm base
git push -q origin main

echo "pin.sh"
expect "reads the reference past a commented key" "h3nc4/app-dev:7" "${root}/pin.sh"
expect "splits off the repository" "h3nc4/app-dev" "${root}/pin.sh" -r
expect "splits off the tag" "7" "${root}/pin.sh" -t
expect "reads standard input" "7" pinned main:.devcontainer.json -t
printf '{ "image": "registry:5000/app-dev" }\n' >"${work}/untagged.json"
if "${root}/pin.sh" "${work}/untagged.json" >/dev/null 2>&1; then
  fail "refuses a reference whose only colon is a port"
else
  ok "refuses a reference whose only colon is a port"
fi

echo "bump.sh"
git checkout -qb untouched
echo more >>README.md
git commit -qam "edit readme"
run bump.sh BASE_REF=main HEAD_REF=untouched
expect "leaves the pin alone when the inputs are untouched" "0 false" outcome bumped

git checkout -qb touched main
echo 'RUN true' >>docker/dev.Dockerfile
git commit -qam "change image"
git push -q origin touched
run bump.sh BASE_REF=main HEAD_REF=touched
expect "bumps when an input moved" "0 true h3nc4/app-dev:8" outcome bumped image
expect "pushes the pin to the branch" "h3nc4/app-dev:8" pinned touched:.devcontainer.json
expect "commits as the configured author" "ci" git log -1 --format=%an
expect "keeps the commented key as it was" "1" grep -c 'old/commented:1' .devcontainer.json

run bump.sh BASE_REF=main HEAD_REF=touched
expect "a second run finds the pin already moved" "0 false 8" outcome bumped version

git checkout -qb renamed main
echo 'RUN true' >>docker/dev.Dockerfile
pin h3nc4/other-dev:7
git commit -qam "rename image"
run bump.sh BASE_REF=main HEAD_REF=renamed
expect "refuses a branch that renames the image" "1" outcome
expect_log "says why" "has to name the same repository"

git checkout -q main
pin h3nc4/app-dev:07
git commit -qam "zero-padded pin"
git push -q origin main
git checkout -qb padded
echo 'RUN true' >>docker/dev.Dockerfile
git commit -qam "change image"
run bump.sh BASE_REF=main HEAD_REF=padded
expect "refuses a base version with a leading zero" "1" outcome
git checkout -q main
git reset -q --hard HEAD~1
git push -q -f origin main

echo "release.sh"
git checkout -q main
git merge -q --ff-only touched
git push -q origin main
run release.sh
expect "publishes a pin the registry lacks" "0 true 8" outcome released version
expect "builds before it pushes" "build -f docker/dev.Dockerfile -t h3nc4/app-dev:8 -t h3nc4/app-dev:latest . push h3nc4/app-dev:8 push h3nc4/app-dev:latest" calls
expect "leaves no git tag behind" "" git --git-dir="${remote}" tag -l

run release.sh
expect "skips a published pin with nothing moved" "0 false" outcome released
expect "and builds nothing" "" calls

git clone -q --depth 1 "file://${remote}" "${work}/shallow"
run release.sh GITHUB_WORKSPACE="${work}/shallow"
expect "deepens a shallow checkout to find the pin commit" "0 false" outcome released

echo 'RUN false' >>docker/dev.Dockerfile
git commit -qam "change image without a bump"
run release.sh
expect "fails when an input moved without a bump" "1" outcome
expect_log "names the file that moved" "docker/dev.Dockerfile"
git reset -q --hard HEAD~1

run release.sh DOCKERFILES="docker/ci.Dockerfile docker/dev.Dockerfile" IMAGE_INPUTS="docker/ci.Dockerfile docker/dev.Dockerfile"
expect "derives the ci image from its Dockerfile" "1" called "build -f docker/ci.Dockerfile -t h3nc4/app-ci:8 -t h3nc4/app-ci:latest ."
expect "publishes only the image the registry lacks" "0" called "push h3nc4/app-dev:8"

run release.sh DOCKERFILES="docker/ci.Dockerfile docker/dev.Dockerfile"
expect "refuses a Dockerfile missing from the image inputs" "1" outcome
expect_log "says which" "docker/ci.Dockerfile is missing from image-inputs"

echo "h3nc4/app-dev:8" >"${work}/refused"
run release.sh
expect "fails when the registry cannot answer" "1 " outcome released
expect_log "quotes the registry" "unauthorized"
: >"${work}/refused"

git checkout -qb merged
echo 'RUN true' >>docker/dev.Dockerfile
pin h3nc4/app-dev:9
git commit -qam "change image and pin"
echo 'RUN true' >>docker/dev.Dockerfile
git commit -qam "change image after the pin"
git checkout -q main
git merge -q --no-ff -m "merge" merged
run release.sh
expect "publishes a pin brought in by a merge commit" "0 true 9" outcome released version
run release.sh
expect "and counts the merge as the pin commit" "0 false" outcome released

echo 'RUN true' >>docker/dev.Dockerfile
pin h3nc4/app-dev:10
git commit -qam "change image and pin"
echo "manifest unknown" >"${work}/missing"
run release.sh
expect "publishes a pin Forgejo's registry calls unknown" "0 true 10" outcome released version
: >"${work}/missing"

echo 'RUN true' >>docker/dev.Dockerfile
pin h3nc4/app-dev:11
git commit -qam "change image and pin"
echo "h3nc4/app-dev:11" >"${work}/limited"
run release.sh PUSH_RETRY_DELAY=0
expect "pushes again after a rate limit" "0 true 11" outcome released version
expect "and the registry holds the version" "1" grep -c -x -F "h3nc4/app-dev:11" "${work}/registry"
expect_log "says it waited" "rate limited"

echo
if [ "${failures}" -ne 0 ]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
