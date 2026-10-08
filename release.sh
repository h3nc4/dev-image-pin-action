#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Publishes whichever images named in the dev container pin the registry lacks. Called by
# release/action.yml, which documents every variable read here.

set -eu

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set. This runs under GitHub Actions.}"

cd "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set. This runs under GitHub Actions.}"

pin="$(dirname "$0")/pin.sh"
docker="${DOCKER:-docker}"
file="${DEVCONTAINER_FILE:-.devcontainer.json}"
image_inputs="${IMAGE_INPUTS:-docker/dev.Dockerfile scripts/entrypoint.sh scripts/switch-user.sh}"
dockerfiles="${DOCKERFILES:-docker/dev.Dockerfile}"

repo="$("${pin}" -r "${file}")"
version="$("${pin}" -t "${file}")"

# Each docker/<flavour>.Dockerfile publishes <name>-<flavour>, so dev.Dockerfile is the pin itself.
images=""
for dockerfile in ${dockerfiles}; do
  case " ${image_inputs} " in
    *" ${dockerfile} "*) ;;
    *)
      echo "::error::${dockerfile} is missing from image-inputs, so a change to it would never bump the pin"
      exit 1
      ;;
  esac
  flavour="$(basename "${dockerfile}" .Dockerfile)"
  if [ "${flavour}" = "$(basename "${dockerfile}")" ]; then
    echo "::error::${dockerfile} is not named <flavour>.Dockerfile, so no image name follows from it"
    exit 1
  fi
  if [ "${flavour}" = "dev" ]; then
    image="${repo}"
  elif [ "${repo%-dev}" != "${repo}" ]; then
    image="${repo%-dev}-${flavour}"
  else
    echo "::error::${repo} does not end in -dev, so ${dockerfile} has no name to derive"
    exit 1
  fi
  images="${images} ${dockerfile}=${image}"
done

echo "version=${version}" >>"${GITHUB_OUTPUT}"

# The registry is the record of a release. A tag already there is never pushed again.
missing=""
for pair in ${images}; do
  ref="${pair#*=}:${version}"
  if probe="$("${docker}" manifest inspect "${ref}" 2>&1 >/dev/null)"; then
    echo "${ref} is already published" >&2
    continue
  fi
  # Docker Hub's absent tag reads "no such manifest", and Forgejo's reads "manifest unknown".
  case "${probe}" in
    *"no such manifest"* | *"manifest unknown"*) missing="${missing} ${pair}" ;;
    *)
      echo "::error::could not ask the registry for ${ref}: ${probe}"
      exit 1
      ;;
  esac
done

if [ -z "${missing}" ]; then
  shallow="$(git rev-parse --is-shallow-repository)"
  if [ "${shallow}" = "true" ]; then
    git fetch --quiet --unshallow origin
  fi
  # Read along the first parent. A merge commit then counts as the one that moved the pin here.
  pinned_at="$(git log -1 --first-parent --diff-merges=first-parent --no-patch --format=%H \
    -G '"image"[[:space:]]*:' -- "${file}")"
  if [ -z "${pinned_at}" ]; then
    echo "::error::no commit in this history sets the image key of ${file}"
    exit 1
  fi
  # shellcheck disable=SC2086
  changed="$(git diff --name-only "${pinned_at}" HEAD -- ${image_inputs})"
  if [ -n "${changed}" ]; then
    changed="$(printf '%s\n' "${changed}" | tr '\n' ' ')"
    echo "::error::${repo}:${version} is already published, but these moved since the pin" \
      "did: ${changed% }. Open a pull request so the bump is merged with the change."
    exit 1
  fi
  echo "::notice::${repo}:${version} is published and nothing has moved since, so there is nothing to do"
  echo "released=false" >>"${GITHUB_OUTPUT}"
  exit 0
fi

# Every missing image builds before any is pushed. A failed build then publishes none of them.
for pair in ${missing}; do
  "${docker}" build -f "${pair%%=*}" -t "${pair#*=}:${version}" -t "${pair#*=}:latest" .
done
published=""
for pair in ${missing}; do
  "${docker}" push "${pair#*=}:${version}"
  "${docker}" push "${pair#*=}:latest"
  published="${published} ${pair#*=}:${version}"
done
echo "::notice::published${published}"
echo "released=true" >>"${GITHUB_OUTPUT}"
