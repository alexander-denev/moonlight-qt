#!/usr/bin/env bash
# Keeps the hybrid-mouse branch on top of upstream's latest release and decides
# whether a new hybrid-mouse release is due.
#
# Run from the root of this repository's checkout, on the hybrid-mouse branch.
#
# Required environment:
#   UPSTREAM          owner/repo this repository was forked from
#   BRANCH            the branch carrying our changes (hybrid-mouse)
#   GH_TOKEN          token that can read upstream releases and this repository's releases
#   GITHUB_REPOSITORY this repository (owner/repo)
# Optional environment:
#   UPSTREAM_TAG      release tag to follow (default: upstream's "Latest" release)
#   FORCE_RELEASE     "true" to release even when nothing changed
#   DRY_RUN           "true" to change nothing outside this checkout
#   SUB_PATH          submodule path that points at our fork of a library
#   SUB_UPSTREAM      owner/repo the submodule's upstream points at
#   SUB_FORK          owner/repo of our fork of the submodule
#   SUB_DIR           checkout of SUB_FORK on its hybrid-mouse branch
#   SUB_SUBJECT       subject of our commit that points the submodule at SUB_FORK
#
# Writes key=value lines to $GITHUB_OUTPUT (or stdout): release, sha, tag,
# title, base_desc, conflict, conflict_commit.
set -euo pipefail

out() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }
note() { echo "::notice::$*"; }
die_conflict() {
    # $1 = which repository, $2 = commit that failed to apply
    git cherry-pick --abort 2>/dev/null || true
    out conflict "$1"
    out conflict_commit "$2"
    out release false
    echo "::error::Could not apply $2 on top of upstream $UPSTREAM_TAG in $1. A person has to resolve this."
    exit 2
}

# Apply commits in order on the current HEAD. Commits whose change is already
# upstream are skipped. $1 = label for errors, rest = commits.
replay() {
    local label=$1; shift
    local c
    for c in "$@"; do
        local before
        before=$(git rev-parse HEAD)
        if ! git cherry-pick --allow-empty --keep-redundant-commits "$c" >/dev/null 2>&1; then
            if [ -z "$(git diff --name-only --diff-filter=U)" ] && git diff --cached --quiet; then
                git cherry-pick --skip
            else
                die_conflict "$label" "$(git log -1 --format='%h %s' "$c")"
            fi
        fi
        # Drop commits that became empty because upstream already has them
        if [ "$(git rev-parse HEAD)" != "$before" ] && git diff --quiet "$before" HEAD; then
            note "Skipping $(git log -1 --format='%h %s' "$c"): upstream already has this change"
            git reset -q --hard "$before"
        fi
    done
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

old_head=$(git rev-parse HEAD)

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM.git"
git fetch -q --no-tags upstream master

if [ -z "${UPSTREAM_TAG:-}" ]; then
    UPSTREAM_TAG=$(gh api "repos/$UPSTREAM/releases/latest" --jq .tag_name)
fi
git fetch -q --no-tags upstream "+refs/tags/$UPSTREAM_TAG:refs/upstream-tags/$UPSTREAM_TAG"
target=$(git rev-parse "refs/upstream-tags/$UPSTREAM_TAG^{commit}")
base=$(git merge-base HEAD upstream/master)
out upstream_tag "$UPSTREAM_TAG"
echo "Upstream latest release: $UPSTREAM_TAG ($target)"
echo "Our branch is based on upstream $base"

rebased=false
if git merge-base --is-ancestor "$target" HEAD; then
    echo "Our branch already contains $UPSTREAM_TAG; no rebase needed."
else
    echo "Rebasing our changes onto $UPSTREAM_TAG"
    mapfile -t patches < <(git rev-list --reverse --no-merges "$base"..HEAD)
    sub_commit=""
    keep=()
    for c in "${patches[@]}"; do
        if [ -n "${SUB_SUBJECT:-}" ] && [ "$(git log -1 --format=%s "$c")" = "$SUB_SUBJECT" ]; then
            sub_commit=$c
        else
            keep+=("$c")
        fi
    done

    git checkout -q -B hybrid-sync-work "$target"
    replay "$GITHUB_REPOSITORY" "${keep[@]}"

    if [ -n "${SUB_PATH:-}" ]; then
        [ -n "$sub_commit" ] || { echo "::error::No commit titled '$SUB_SUBJECT' found"; exit 1; }
        old_pin=$(git ls-tree "$base" "$SUB_PATH" | awk '{print $3}')
        new_pin=$(git ls-tree "$target" "$SUB_PATH" | awk '{print $3}')
        sub_head=$(git -C "$SUB_DIR" rev-parse HEAD)
        if [ "$old_pin" = "$new_pin" ]; then
            new_sub=$sub_head
        else
            echo "Upstream moved $SUB_PATH from $old_pin to $new_pin; rebasing $SUB_FORK"
            (
                cd "$SUB_DIR"
                git config user.name "github-actions[bot]"
                git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
                git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$SUB_UPSTREAM.git"
                git fetch -q --no-tags upstream "$new_pin"
                mapfile -t sub_patches < <(git rev-list --reverse --no-merges "$old_pin"..HEAD)
                git checkout -q -B hybrid-sync-work "$new_pin"
                replay "$SUB_FORK" "${sub_patches[@]}"
            )
            new_sub=$(git -C "$SUB_DIR" rev-parse HEAD)
        fi

        name=$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk -v p="$SUB_PATH" '$2==p{print $1}' | sed -E 's/^submodule\.(.*)\.path$/\1/')
        git config -f .gitmodules "submodule.$name.url" "https://github.com/$SUB_FORK.git"
        git update-index --cacheinfo "160000,$new_sub,$SUB_PATH"
        git add .gitmodules
        git commit -q -m "$SUB_SUBJECT" -m "Points the submodule at $SUB_FORK, which carries the cursor protocol v2
client on top of the commit upstream $UPSTREAM_TAG pins."
    fi
    rebased=true
fi

sha=$(git rev-parse HEAD)
out sha "$sha"
out rebased "$rebased"

# Describe what we are built on, for the release title and notes
if [ "$(git merge-base HEAD upstream/master)" = "$target" ] || [ "$rebased" = true ]; then
    base_desc="upstream release $UPSTREAM_TAG"
    title_base="$UPSTREAM_TAG"
else
    short_base=$(git rev-parse --short=10 "$(git merge-base HEAD upstream/master)")
    base_desc="upstream master at $short_base (newer than release $UPSTREAM_TAG)"
    title_base="upstream master $short_base"
fi
out base_desc "$base_desc"

# Is a release due? Yes if we rebased, if we never released, if the branch
# moved since the last release, or if asked.
last_tag=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
            --jq '[.[] | select(.tag_name | startswith("hybrid-"))] | sort_by(.created_at) | last | .tag_name // ""')
last_sha=""
if [ -n "$last_tag" ]; then
    git fetch -q --no-tags origin "+refs/tags/$last_tag:refs/tags/$last_tag" 2>/dev/null || true
    last_sha=$(git rev-parse -q --verify "refs/tags/$last_tag^{commit}" || true)
fi
release=false
if [ "$rebased" = true ] || [ -z "$last_tag" ] || [ "$last_sha" != "$sha" ] || [ "${FORCE_RELEASE:-false}" = true ]; then
    release=true
fi
echo "Last hybrid release: ${last_tag:-none} (${last_sha:-n/a}); release due: $release"

tag="hybrid-$(date -u +%Y%m%d-%H%M)"
out tag "$tag"
out title "Hybrid mouse $(date -u +%Y-%m-%d), based on $title_base"
out release "$release"
out conflict ""

if [ "${DRY_RUN:-false}" = true ]; then
    note "Dry run: not pushing"
    exit 0
fi

if [ "$rebased" = true ]; then
    if [ -n "${SUB_PATH:-}" ] && [ "$new_sub" != "$sub_head" ]; then
        git -C "$SUB_DIR" push -q --force-with-lease="$BRANCH:$sub_head" origin "HEAD:refs/heads/$BRANCH"
    fi
    git push -q --force-with-lease="$BRANCH:$old_head" origin "HEAD:refs/heads/$BRANCH"
    note "Rebased $BRANCH onto $UPSTREAM_TAG and pushed $sha"
fi

# Keep the submodule commit a release uses reachable, even after later rebases
if [ "$release" = true ] && [ -n "${SUB_PATH:-}" ]; then
    pin=$(git ls-tree HEAD "$SUB_PATH" | awk '{print $3}')
    git -C "$SUB_DIR" fetch -q origin "$pin" 2>/dev/null || true
    git -C "$SUB_DIR" push -q origin "$pin:refs/tags/$tag"
fi
