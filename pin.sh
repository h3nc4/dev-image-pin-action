#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

# Usage: pin.sh [-r|-t] [file]. Prints the image a dev container definition pins, or with -r
# its repository and with -t its tag. The file defaults to .devcontainer.json, and - is stdin.

set -eu

part="ref"
case "${1:-}" in
  -r)
    part="repo"
    shift
    ;;
  -t)
    part="tag"
    shift
    ;;
  *) ;;
esac

file="${1:-.devcontainer.json}"
if [ "${file}" != "-" ] && [ ! -f "${file}" ]; then
  echo "${file} is not there" >&2
  exit 1
fi

# The first "image" key is the top-level one. A // comment moves a key away from the start of its line.
ref="$(
  sed -n 's/^[[:space:]]*"image"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${file}" |
    head -n 1
)"
if [ -z "${ref}" ]; then
  echo "no image key in ${file}" >&2
  exit 1
fi

# The colon has to sit in the last path element, since an earlier one is a registry's port.
case "${ref##*/}" in
  *:?*) ;;
  *)
    echo "the image in ${file} is '${ref}', which carries no tag" >&2
    exit 1
    ;;
esac

case "${part}" in
  repo) printf '%s\n' "${ref%:*}" ;;
  tag) printf '%s\n' "${ref##*:}" ;;
  *) printf '%s\n' "${ref}" ;;
esac
