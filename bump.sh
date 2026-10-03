#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Moves a pull request's dev container pin to one past the base branch's, when the change touches
# the image inputs. Called by bump/action.yml, which documents every variable read here.

set -eu

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set. This runs under GitHub Actions.}"
: "${BASE_REF:?BASE_REF is not set. The bump runs on a pull_request event.}"
: "${HEAD_REF:?HEAD_REF is not set. The bump runs on a pull_request event.}"

cd "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set. This runs under GitHub Actions.}"

pin="$(dirname "$0")/pin.sh"
file="${DEVCONTAINER_FILE:-.devcontainer.json}"
image_inputs="${IMAGE_INPUTS:-docker/dev.Dockerfile scripts/entrypoint.sh scripts/switch-user.sh}"

git fetch --quiet origin "${BASE_REF}"
base_tip="$(git rev-parse FETCH_HEAD)"
if ! base="$(git merge-base "${base_tip}" HEAD)"; then
  echo "::error::HEAD shares no history with ${BASE_REF}. Check out with fetch-depth: 0."
  exit 1
fi

# image_inputs is a space-separated list of paths, so it is split on purpose.
# shellcheck disable=SC2086
changed="$(git diff --name-only "${base}" HEAD -- ${image_inputs})"
if [ -z "${changed}" ]; then
  echo "::notice::the image inputs are untouched, leaving the pin alone"
  echo "bumped=false" >>"${GITHUB_OUTPUT}"
  exit 0
fi

base_pin="$(git show "${base_tip}:${file}")"
repo="$(printf '%s\n' "${base_pin}" | "${pin}" -r -)"
base_version="$(printf '%s\n' "${base_pin}" | "${pin}" -t -)"
case "${base_version}" in # Leading zeroes are refused, since shell arithmetic reads them as octal
  "" | *[!0-9]* | 0?*)
    echo "::error::${BASE_REF} pins ${repo}:${base_version}, and only a plain number can be bumped"
    exit 1
    ;;
  *) ;;
esac
version=$((base_version + 1))

sed -i "s|\(\"image\"[[:space:]]*:[[:space:]]*\"${repo}\):[^\"]*\"|\1:${version}\"|" "${file}"
if ! grep -q "\"${repo}:${version}\"" "${file}"; then
  echo "::error::${file} does not pin ${repo}:${version}." \
    "Its image key has to name the same repository as ${BASE_REF} does."
  exit 1
fi

{
  echo "image=${repo}:${version}"
  echo "version=${version}"
} >>"${GITHUB_OUTPUT}"

if git diff --quiet -- "${file}"; then
  echo "::notice::already pinned to ${repo}:${version}"
  echo "bumped=false" >>"${GITHUB_OUTPUT}"
  exit 0
fi

git -c user.name="${AUTHOR_NAME:?}" -c user.email="${AUTHOR_EMAIL:?}" \
  commit -qm "${COMMIT_MESSAGE:-Bump dev container to} ${version}" -- "${file}"
git push --quiet origin "HEAD:${HEAD_REF}"
echo "::notice::pinned ${repo}:${version} on ${HEAD_REF}"
echo "bumped=true" >>"${GITHUB_OUTPUT}"
