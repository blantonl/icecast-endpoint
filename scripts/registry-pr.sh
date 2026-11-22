#!/usr/bin/env bash
# Get a release into the plugin registry (github.com/TrunkRecorder/plugins), checked at every step.
#
#   scripts/registry-pr.sh prepare <X.Y.Z> [--registry DIR]
#       Check the release (tag, GitHub release, workflow, archives, provenance) and the registry
#       clone, then write, check and commit the entry on branch icecast-endpoint-X.Y.Z.
#       Prints the push command. Pushes nothing.
#   scripts/registry-pr.sh verify <X.Y.Z> [--registry DIR]
#       After the push: check the branch reached the canonical repo and, through its mirror, the
#       GitHub fork; that it merges cleanly; and whether a PR exists. Only then prints the steps
#       to open the pull request.
#
# DIR (default $REGISTRY_DIR) is a clone of the registry whose `origin` is the canonical (non-GitHub)
# copy of your fork. The GitHub fork is a push mirror of it that deletes branches it doesn't have:
# a branch pushed straight to the GitHub fork is deleted at the next sync and its PR closes itself.
#
# Needs git, gh (read-only API calls only), jq, python3. Never writes to GitHub.
set -euo pipefail

UPSTREAM=TrunkRecorder/plugins
here=$(cd "$(dirname "$0")/.." && pwd)

C_OK='' C_WARN='' C_FAIL='' C_END=''
if [[ -t 1 ]]; then C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m' C_END=$'\033[0m'; fi
ok() { printf '  %sok%s    %s\n' "$C_OK" "$C_END" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$C_WARN" "$C_END" "$*"; }
fail() {
    printf '  %sFAIL%s  %s\n' "$C_FAIL" "$C_END" "$*" >&2
    exit 1
}
step() { printf '\n%s\n' "$*"; }
usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

cmd=${1:-}
version=${2:-}
[[ $cmd == prepare || $cmd == verify ]] || usage
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
shift 2
registry=${REGISTRY_DIR:-}
while [[ $# -gt 0 ]]; do
    case $1 in
    --registry)
        registry=${2:-}
        shift 2
        ;;
    *) usage ;;
    esac
done
[[ -n $registry ]] || fail "say where the registry clone is: --registry DIR or REGISTRY_DIR"
[[ -d $registry/.git && -f $registry/tools/registry.py ]] || fail "$registry isn't a clone of $UPSTREAM"
for t in git gh jq python3; do command -v "$t" >/dev/null || fail "$t isn't installed"; done

id=$(sed -n 's/^name = "\(.*\)"/\1/p' "$here/Cargo.toml" | head -1)
repo_url=$(sed -n 's/^repository = "\(.*\)"/\1/p' "$here/Cargo.toml" | head -1)
repo=${repo_url#https://github.com/}
tag=v$version
branch=$id-$version
reg() { git -C "$registry" "$@"; }

# ─── The release ───────────────────────────────────────────────────────────

check_release() {
    step "Release $tag of $repo"
    local cargo
    cargo=$(sed -n 's/^version = "\(.*\)"/\1/p' "$here/Cargo.toml" | head -1)
    [[ $cargo == "$version" ]] || warn "Cargo.toml here is at $cargo (checking the tag's own below)"
    git -C "$here" fetch -q --tags origin || fail "can't fetch tags from this repo's origin"
    local local_sha origin_sha gh_sha
    local_sha=$(git -C "$here" rev-parse -q --verify "$tag^{commit}") || fail "no tag $tag here"
    git -C "$here" show "$tag:Cargo.toml" | grep -q "^version = \"$version\"" || fail "Cargo.toml at $tag isn't version $version"
    git -C "$here" show "$tag:CHANGELOG.md" | grep -qF "## [$version]" || fail "CHANGELOG.md at $tag has no ## [$version] section"
    ok "tag $tag: Cargo.toml $version, CHANGELOG has ## [$version]"
    origin_sha=$(git -C "$here" ls-remote origin "refs/tags/$tag^{}" "refs/tags/$tag" | awk 'END{print $1}')
    [[ $origin_sha == "$local_sha" ]] || fail "origin's $tag (${origin_sha:-missing}) isn't $local_sha: push the tag to origin"
    gh_sha=$(gh api "repos/$repo/commits/$tag" --jq .sha 2>/dev/null) || fail "$tag isn't on GitHub yet: wait for the mirror to sync, or sync it now"
    [[ $gh_sha == "$local_sha" ]] || fail "GitHub's $tag is $gh_sha, origin's is $local_sha"
    ok "$tag is ${local_sha:0:7} on origin and on GitHub"
    tag_sha=$local_sha

    local rel
    rel=$(gh api "repos/$repo/releases/tags/$tag" 2>/dev/null) || fail "no GitHub release for $tag yet (is the Release workflow still running?)"
    [[ $(jq -r '.draft or .prerelease' <<<"$rel") == false ]] || fail "the $tag release is a draft or prerelease"
    local run
    run=$(gh api "repos/$repo/actions/runs?event=push&branch=$tag&per_page=20" \
        --jq '[.workflow_runs[] | select(.name == "Release")][0] | "\(.status) \(.conclusion)"')
    [[ $run == "completed success" ]] || fail "the Release workflow for $tag is '$run', not 'completed success'"
    ok "release published; Release workflow succeeded"

    local sums
    sums=$(gh release download "$tag" -R "$repo" -p SHA256SUMS -O - 2>/dev/null) || fail "can't read SHA256SUMS from the release"
    for f in "$id-$version.manifest.json" SHA256SUMS; do
        jq -e --arg f "$f" '.assets | any(.name == $f)' <<<"$rel" >/dev/null || fail "the release has no $f"
    done
    archives=0
    for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu universal-apple-darwin x86_64-pc-windows-msvc; do
        local name sha digest n
        name=$(jq -r --arg p "$id-$version-$target." '.assets[] | select(.name | startswith($p)) | .name' <<<"$rel")
        [[ -n $name ]] || fail "the release has no archive for $target"
        sha=$(awk -v n="$name" '$2 == n || $2 == "*"n {print $1}' <<<"$sums")
        [[ -n $sha ]] || fail "SHA256SUMS doesn't list $name"
        digest=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest // ""' <<<"$rel")
        [[ -z $digest || $digest == "sha256:$sha" ]] || fail "$name: GitHub's digest $digest doesn't match SHA256SUMS"
        n=$(gh api "repos/$repo/attestations/sha256:$sha" --jq '.attestations | length' 2>/dev/null || echo 0)
        [[ $n -gt 0 ]] || fail "$name has no build provenance attestation"
        archives=$((archives + 1))
    done
    ok "$archives archives, each in SHA256SUMS with a provenance attestation; manifest present"
}

# ─── The registry clone ────────────────────────────────────────────────────

check_clone() {
    step "Registry clone $registry"
    local origin up uppush
    origin=$(reg remote get-url --push origin 2>/dev/null) || fail "the clone has no origin"
    [[ $origin != *github* ]] || fail "origin is GitHub ($origin). Its GitHub fork is a mirror: a branch pushed there is deleted at the next sync and the PR closes. Make origin the canonical repo the mirror syncs from."
    ok "origin is the canonical repo, not GitHub"
    up=$(reg remote get-url upstream 2>/dev/null) || fail "the clone has no upstream remote ($UPSTREAM)"
    [[ $up == *"$UPSTREAM"* ]] || fail "upstream is $up, not $UPSTREAM"
    uppush=$(reg remote get-url --push upstream)
    [[ $uppush != *github.com* ]] || warn "upstream can be pushed to; set its push URL to DISABLED"
    ok "upstream is $UPSTREAM"
    [[ -z $(reg status --porcelain) ]] || fail "the clone has uncommitted changes"
    reg fetch -q upstream || fail "can't fetch upstream"
    reg fetch -q --prune origin || fail "can't fetch origin"
    ok "clean; fetched upstream and origin"
    # The GitHub fork, for verify: the clone's github remote, else <your login>/plugins.
    fork=$(reg remote get-url github 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##') || true
    [[ -n $fork ]] || fork="$(gh api user --jq .login)/plugins"
    owner=${fork%%/*}
}

# This repo's release versions, oldest first.
release_tags() {
    git -C "$here" tag | sed -n 's/^v//p' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}

listed_version() {
    gh api "repos/$UPSTREAM/contents/plugins/$id.json" --jq .content 2>/dev/null | base64 -d | jq -r .version 2>/dev/null || echo none
}

check_listing() {
    listed=$(listed_version)
    local previous
    previous=$(release_tags | awk -v v="$version" '$0 == v {print p; exit} {p = $0}')
    if [[ $listed == none ]]; then
        warn "the registry doesn't list $id yet: this adds it"
    elif [[ $(printf '%s\n%s\n' "$listed" "$version" | sort -V | tail -1) != "$version" || $listed == "$version" ]]; then
        warn "the registry already lists $listed (not older than $version)"
    elif [[ -n $previous && $listed != "$previous" ]]; then
        warn "the registry lists $listed; $previous was never submitted (this PR covers both)"
    else
        ok "the registry lists $listed"
    fi
}

registry_check() {
    if gh attestation --help >/dev/null 2>&1; then
        check_mode=full
        (cd "$registry" && python3 -I tools/registry.py check "plugins/$id.json") || fail "the registry's check failed"
        ok "registry check (full: checksums, provenance, --describe)"
    else
        check_mode=quick
        (cd "$registry" && python3 -I tools/registry.py check --quick "plugins/$id.json") || fail "the registry's check --quick failed"
        ok "registry check --quick (this gh has no 'gh attestation'; provenance was checked above through the API, and the registry's CI runs the full check)"
    fi
}

check_entry() {
    local entry
    entry=$(reg show "$branch:plugins/$id.json") || fail "$branch has no plugins/$id.json"
    [[ $(jq -r .version <<<"$entry") == "$version" ]] || fail "the entry's version isn't $version"
    [[ $(jq -r .tag <<<"$entry") == "$tag" ]] || fail "the entry's tag isn't $tag"
    [[ $(jq -r .commit <<<"$entry") == "$tag_sha" ]] || fail "the entry's commit isn't $tag's ($tag_sha)"
    [[ $(jq -r '.assets | length' <<<"$entry") == 4 ]] || fail "the entry doesn't have 4 platforms"
    local base files
    base=$(reg merge-base upstream/main "$branch")
    files=$(reg diff --name-only "$base" "$branch" | sort | tr '\n' ' ')
    [[ $files == "index.json plugins/$id.json " ]] || fail "$branch changes more than index.json and plugins/$id.json: $files"
    reg merge-tree --write-tree upstream/main "$branch" >/dev/null 2>&1 || fail "$branch doesn't merge cleanly into upstream/main: rebase it"
    ok "entry: $version, $tag at ${tag_sha:0:7}, 4 platforms; only the 2 files change; merges cleanly"
}

# ─── prepare ───────────────────────────────────────────────────────────────

prepare() {
    check_release
    check_clone
    check_listing
    step "Entry on branch $branch"
    if reg rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
        reg switch -q "$branch"
        ok "branch $branch exists; checking it"
    else
        reg switch -q -c "$branch" upstream/main
        ok "branch $branch from upstream/main"
    fi
    python3 -I "$registry/tools/registry.py" add-release "$repo_url" "$tag" >/dev/null || fail "add-release failed"
    registry_check
    if [[ -n $(reg status --porcelain) ]]; then
        reg add index.json "plugins/$id.json"
        ! reg status --porcelain | grep -qv '^[MA]  ' || fail "add-release changed files other than the entry and index.json: $(reg status --porcelain | grep -v '^[MA]  ' | tr '\n' ' ')"
        reg commit -q -m "$(jq -r .name "$registry/plugins/$id.json") $version"
        ok "committed $(reg rev-parse --short HEAD)"
    else
        ok "the entry was already committed"
    fi
    check_entry

    step "Next: push to origin (the canonical repo; never to GitHub), then verify"
    if ! reg merge-base --is-ancestor upstream/main origin/main 2>/dev/null; then
        echo "  git -C $registry push origin upstream/main:refs/heads/main   # origin's main is behind upstream"
    fi
    echo "  git -C $registry push -u origin $branch"
    echo "  scripts/registry-pr.sh verify $version --registry $registry"
}

# ─── verify ────────────────────────────────────────────────────────────────

verify() {
    check_release
    check_clone
    check_listing
    step "Branch $branch"
    local local_sha origin_sha fork_sha
    local_sha=$(reg rev-parse -q --verify "refs/heads/$branch") || fail "no branch $branch: run prepare first"
    origin_sha=$(reg ls-remote origin "refs/heads/$branch" | awk '{print $1}')
    [[ -n $origin_sha ]] || fail "$branch isn't on origin: git -C $registry push -u origin $branch"
    [[ $origin_sha == "$local_sha" ]] || fail "origin's $branch (${origin_sha:0:7}) isn't the local one (${local_sha:0:7}): push it to origin"
    ok "on origin at ${local_sha:0:7}"
    for _ in $(seq 12); do
        fork_sha=$(gh api "repos/$fork/branches/$branch" --jq .commit.sha 2>/dev/null) || fork_sha=
        [[ $fork_sha == "$local_sha" ]] && break
        sleep 10
    done
    [[ $fork_sha == "$local_sha" ]] || fail "the GitHub fork $fork doesn't have $branch at ${local_sha:0:7} (${fork_sha:-missing}) after 2 minutes: sync the mirror now and verify again"
    ok "the mirror carried it to $fork"
    check_entry
    reg switch -q "$branch"
    registry_check

    step "Pull requests from $owner:$branch"
    local prs open
    prs=$(gh api "repos/$UPSTREAM/pulls?state=all&head=$owner:$branch" --jq '.[] | "\(.number) \(.state) \(.merged_at != null) \(.html_url)"')
    open=$(awk '$2 == "open"' <<<"$prs")
    if [[ -n $open ]]; then
        ok "already open: $(awk '{print $4}' <<<"$open"). Nothing more to do; CI re-runs on its own."
        return
    fi
    while read -r n _ merged url; do
        [[ -n ${n:-} ]] || continue
        if [[ $merged == true ]]; then
            ok "already merged: $url"
            return
        fi
        warn "#$n is closed, not merged ($url): press Reopen pull request on it instead of opening a new one"
    done <<<"$prs"
    [[ -z $prs ]] && ok "none yet"

    # Every check passed: the steps for the person opening it.
    local name versions body
    name=$(jq -r .name "$registry/plugins/$id.json")
    versions=$(release_tags | while read -r v; do
        [[ $listed == none || ($v != "$listed" && $(printf '%s\n%s\n' "$listed" "$v" | sort -V | head -1) == "$listed") ]] || continue
        echo "$v"
        [[ $v == "$version" ]] && break
    done)
    body="Updates **$name** from $listed to **$version** (community). The entry was written by \`./add-release\`."
    if [[ $check_mode == full ]]; then
        body+=" \`./check\` passes."
    else
        body+=" \`./check --quick\` passes, and all four archives have build provenance attestations."
    fi
    body+=$'\n'
    for v in $versions; do
        body+=$'\n'"- **$v**: https://github.com/$repo/releases/tag/v$v"
    done
    if [[ -z $prs ]]; then
        step "All checks passed. To open the pull request:"
        cat <<EOF
  1. Open https://github.com/$UPSTREAM/compare/main...$owner:${fork#*/}:$branch
  2. Press Create pull request.
  3. Title: $name $version
  4. Description (paste as is; add a line on what changed if you like):

$body
EOF
    else
        step "All checks passed. Reopen the closed PR above (Reopen pull request): its branch is back at ${local_sha:0:7}."
    fi
}

"$cmd"
