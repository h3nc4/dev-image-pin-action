# dev-image-pin-action

Moves a project's dev container pin in the same pull request as the change that rebuilds the image, and publishes that image once the pull request merges.

The image key of `.devcontainer.json` names the dev image and its version, such as `h3nc4/app-dev:7`. A pull request touching the Dockerfile has that key moved to `8` by `bump`, in a commit pushed to the pull request's own branch. After the merge, `release` finds `h3nc4/app-dev:8` missing from the registry, then builds and pushes it along with `latest`. The registry is the only record of a release. Git tags are left to the project itself. The default branch only ever pins an image built from its own tree, and [h3nc4/dev-image-action](https://github.com/h3nc4/dev-image-action) builds the unpublished `8` from the checkout while the pull request is open.

```yaml
name: Dev Container

on:
  pull_request:
    branches:
      - "main"
  push:
    branches:
      - "main"
  workflow_dispatch:

jobs:
  bump:
    name: Pin the next dev container
    if: >-
      github.event_name == 'pull_request' &&
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    concurrency:
      group: ${{ github.workflow }}-bump-${{ github.ref }}
    permissions:
      contents: write # pushes the pin to this pull request's branch
    steps:
      - id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: "4811373"
          private-key: ${{ secrets.AUTOMERGE_APP_PRIVATE_KEY }}
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          ref: ${{ github.head_ref }}
          token: ${{ steps.app-token.outputs.token }}
          fetch-depth: 0
      - uses: h3nc4/dev-image-pin-action/bump@v1

  release:
    name: Publish the pinned dev container
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    concurrency:
      group: ${{ github.workflow }}-release
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4
        with:
          username: ${{ vars.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: h3nc4/dev-image-pin-action/release@v1
```

Both triggers can run on every pull request and every push, since each action reads the diff itself and stops early when the image inputs are untouched. A `paths:` filter on the trigger is optional. A list kept there has to match `image-inputs`, because a change to a path the filter omits never starts the bump.

## Before the first run

**Push the pin with a token that starts workflows.** A commit pushed with `GITHUB_TOKEN` does not start a workflow run. The pin commit then becomes a head without checks, which leaves a required check unmet and the pull request unmergeable. Check out with an app token or a bot's personal token, as above, and the push that `bump` makes runs CI like any other.

**Check out with `fetch-depth: 0` for `bump`.** It needs the merge base with the base branch, and a shallow clone fails the job there. `release` deepens a shallow checkout itself when it needs the history.

**Keep the bump author in Renovate's `gitIgnoredAuthors`.** Renovate stops rebasing a branch once it holds a commit by another author. The default author is `github-actions[bot]`, so a repository on GitHub lists `41898282+github-actions[bot]@users.noreply.github.com`, and one whose bot commits under another identity passes `author-name` and `author-email` to match its list.

**Log in before `release`.** The action reads each version's manifest from the registry, then runs `docker build` and `docker push`, and leaves the registry, the user and the secret to the caller. A private registry returns `no such manifest` to an anonymous read even for a published version, so a job missing its login tries to publish again and fails at the push.

**Start the pin at a plain number.** `bump` adds one to the base branch's tag, so `7` works and `7.1`, `v7` and `07` fail the job.

## Inputs

`bump`:

| Input | Default | Meaning |
| --- | --- | --- |
| `devcontainer-file` | `.devcontainer.json` | Definition whose image key carries the pin. |
| `image-inputs` | `docker/dev.Dockerfile scripts/entrypoint.sh scripts/switch-user.sh` | Space-separated paths whose change calls for a new version. Give `dev-image-action` the same list. |
| `base-ref` | the pull request's base | Branch the next version is counted from. |
| `head-ref` | the pull request's head | Branch the pin commit is pushed to. |
| `author-name` | `github-actions[bot]` | Author of the pin commit. |
| `author-email` | `41898282+github-actions[bot]@users.noreply.github.com` | Email Renovate's `gitIgnoredAuthors` matches. |
| `commit-message` | `Bump dev container to` | Commit title, followed by the version. |

Its outputs are `bumped`, `image` and `version`.

`release`:

| Input | Default | Meaning |
| --- | --- | --- |
| `devcontainer-file` | `.devcontainer.json` | Definition whose image key carries the pin. |
| `image-inputs` | same as `bump` | A published pin with any of these moved since the commit that set it fails the job. |
| `dockerfiles` | `docker/dev.Dockerfile` | Space-separated Dockerfiles to publish, each named `<flavour>.Dockerfile`. |

Its outputs are `released` and `version`.

## More than one image

`dockerfiles` publishes each Dockerfile under a name derived from the pin, so a second name never needs configuring. `docker/dev.Dockerfile` publishes the pinned repository itself, and any other flavour swaps the `-dev` ending for its own, so `docker/ci.Dockerfile` beside a pin of `h3nc4/app-dev:8` publishes `h3nc4/app-ci:8`. All of them share the version, and none is pushed until every one has built. Each has to appear in `image-inputs` too, or the job fails before building anything.

## What fails the release

A push to the default branch that changes an image input without moving the pin fails `release`, naming the files that moved since the commit that set the pin. On the default branch that commit is the squash or the merge commit that brought the pin in. That happens after a direct push or after a pull request opened from a fork, where `bump` is skipped. Open a pull request from a branch of the same repository so the bump is merged with the change.

`release` builds with plain `docker build`, so a Forgejo runner whose buildx builder cannot reach the registry works unchanged. GitHub's runners use the same command through their default builder.

## Tests

`./tests/actions.test.sh` walks `pin.sh`, `bump.sh` and `release.sh` through a throwaway repository with a bare remote, with docker replaced by a stub that records each call. It needs git alone.

## License

<!-- vale off -->

BSD 2-Clause License. See [LICENSE](LICENSE).

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
