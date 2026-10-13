#!/usr/bin/env bash
# fizzy's changes to SDL, between the patch files and a jj stack.
#
# `backend/patches/sdl/*.patch` are applied in name order, by zig-patch at build time, to the
# upstream SDL release `backend/build.zig.zon` pins as `.sdl_source`. They are edited as changes
# in a jj checkout of SDL (fizzyedit/SDL, with libsdl-org as a remote), never by hand:
#
#   scripts/sdl-patches.sh import <checkout> <base>
#       stacks the patches on <base> in <checkout>, one change each, described and authored from
#       its header. <base> is the release they were made against (the commit of `release-3.4.16`).
#   scripts/sdl-patches.sh export <checkout> <base> [<tip>]
#       writes the changes <base>..<tip> (default `@-`) over `backend/patches/sdl`, one each.
#
# A change to a patch: import, edit the change it is (`jj edit`, or `jj new` and `jj squash`),
# export. An SDL update: import onto the old release, `jj rebase -s <first> -d <new release>`,
# resolve, export onto the new release, and move `.sdl_source` (docs/DEPENDENCIES.md,
# "Bumping"). A change upstream took comes out empty: abandon it before exporting.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
    exit 2
}

[ $# -ge 3 ] || usage
cmd=$1
checkout=$(cd "$2" && pwd)
base=$3
patches=$(cd "$(dirname "$0")/../backend/patches/sdl" && pwd)

case $cmd in
import)
    [ $# -eq 3 ] || usage
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT
    cd "$checkout"
    # git apply works as a plain `patch` where there is no repository (a secondary jj workspace
    # has no .git), but inside one found above the checkout it skips every path outside the
    # current directory, silently: never look above the checkout.
    export GIT_CEILING_DIRECTORIES=$(dirname "$checkout")
    jj new --quiet "$base"
    for p in "$patches"/*.patch; do
        git apply --whitespace=nowarn "$p"
        [ -n "$(jj diff --name-only)" ] || { echo "$p changed nothing" >&2; exit 1; }
        git mailinfo "$scratch/msg" /dev/null < "$p" > "$scratch/info"
        field() { sed -n "s/^$1: //p" "$scratch/info"; }
        { printf '%s\n\n' "$(field Subject)"; cat "$scratch/msg"; } | jj describe --quiet --stdin
        jj metaedit --quiet --author "$(field Author) <$(field Email)>" --author-timestamp "$(field Date)"
        jj new --quiet
        echo "imported $(basename "$p")"
    done
    ;;
export)
    [ $# -le 4 ] || usage
    cd "$checkout"
    from=$(jj log --no-graph -r "$base" -T commit_id)
    to=$(jj log --no-graph -r "${4:-@-}" -T commit_id)
    git_dir=$(jj git root)
    rm -f "$patches"/*.patch
    # Fixed against a person's git config: a/ b/ prefixes, no signature, no commit id or patch
    # numbers in the header, so a re-export changes only what changed.
    git --git-dir="$git_dir" -c diff.noprefix=false -c diff.mnemonicPrefix=false format-patch \
        --quiet -U8 --zero-commit --no-signature --no-numbered --src-prefix=a/ --dst-prefix=b/ \
        -o "$patches" "$from..$to"
    ls "$patches"
    ;;
*) usage ;;
esac
