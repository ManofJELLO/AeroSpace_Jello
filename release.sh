#!/usr/bin/env bash
# Cut a release of the AeroSpace_Jello fork and publish it to the personal
# Homebrew tap.
#
#   ./release.sh 0.21.3-jello.2              # build, publish, upgrade locally
#   ./release.sh 0.21.3-jello.2 --dry-run    # build + package only, publish nothing
#   ./release.sh 0.21.3-jello.2 --no-upgrade # publish, but don't touch the local install
#
# Deliberately skips build-docs.sh and build-shell-completion.sh (they require
# Ruby gems and Rust). That means no man pages and no shell completions.
# Everything else matches upstream's build-release.sh, including the ad-hoc
# codesign identity ("-") that upstream CI itself uses.

cd "$(dirname "$0")"

set -euo pipefail

readonly REPO="ManofJELLO/AeroSpace_Jello"
readonly TAP_REPO="ManofJELLO/homebrew-tap"
readonly TAP_SHORT="ManofJELLO/tap"
readonly CASK_NAME="aerospace-jello"

die() { echo "error: $*" > /dev/stderr; exit 1; }
step() { echo; echo "==> $*"; }

########################
### Arguments        ###
########################

build_version=''
dry_run=0
do_upgrade=1
while test $# -gt 0; do
    case $1 in
        --dry-run) dry_run=1; shift ;;
        --no-upgrade) do_upgrade=0; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *)
            test -z "$build_version" || die "version specified twice: $build_version and $1"
            build_version=$1; shift ;;
    esac
done

test -n "$build_version" || die "usage: ./release.sh <version> [--dry-run] [--no-upgrade]"
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' <<< "$build_version" \
    || die "version should start with X.Y.Z, got '$build_version'"
# Note: written as `if`, not `grep ... && die`. Under `set -e` a failing `&&` list
# exits the script, so the `&&` form would abort on every valid version.
if grep -q SNAPSHOT <<< "$build_version"; then
    die "SNAPSHOT versions can't be published to a cask (brew needs a real version)"
fi

readonly build_version dry_run do_upgrade
readonly tag="v$build_version"
readonly zip_root="AeroSpace-v$build_version"
readonly zip_name="$zip_root.zip"

########################
### Preflight        ###
########################

step "Preflight"

# setup.sh requires bash 5; generate.sh re-execs through `env bash`, so Homebrew's
# bash has to win over the system's 3.2.
if ! grep -q '^5\.' <<< "${BASH_VERSION:-}"; then
    die "run me with bash 5, e.g. /opt/homebrew/bin/bash ./release.sh $build_version"
fi
if ! grep -q '^5\.' <<< "$(/usr/bin/env bash -c 'echo $BASH_VERSION')"; then
    die "'env bash' resolves to bash 3.x; put /opt/homebrew/bin first on PATH"
fi

# xcodebuild needs full Xcode. CommandLineTools has no XCTest and no app toolchain.
if ! test -d "${DEVELOPER_DIR:-}"; then
    if test -d /Applications/Xcode.app/Contents/Developer; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        die "full Xcode not found; set DEVELOPER_DIR"
    fi
fi
echo "DEVELOPER_DIR=$DEVELOPER_DIR"

command -v git > /dev/null || die "git not found"
test -z "$(git status --porcelain)" \
    || die "working tree is dirty. This script restores generated files with 'git restore', which would eat your changes. Commit or stash first."

cask_file=''
if test $dry_run == 0; then
    command -v gh > /dev/null || die "gh not found. brew install gh"
    gh auth status > /dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
    command -v brew > /dev/null || die "brew not found"

    cask_file="$(brew --repository)/Library/Taps/manofjello/homebrew-tap/Casks/$CASK_NAME.rb"
    test -f "$cask_file" || die "cask not found at $cask_file. Run: brew tap $TAP_REPO"

    if gh release view "$tag" --repo "$REPO" > /dev/null 2>&1; then
        die "release $tag already exists on $REPO. Pick a new version or delete it first."
    fi
fi
readonly cask_file

echo "version:  $build_version"
echo "commit:   $(git rev-parse --short HEAD)"
echo "dry run:  $dry_run"

########################
### Build            ###
########################

# generate.sh rewrites tracked files (versionGenerated.swift, gitHashGenerated.swift,
# cmdHelpGenerated.swift). Always put them back, even if we fail partway.
restore_generated() {
    echo "==> Restoring generated files"
    git restore --staged --worktree . 2> /dev/null || true
}
trap restore_generated EXIT

step "Generating version metadata"
# --ignore-xcodeproj avoids needing xcodegen; the .xcodeproj is committed.
./generate.sh --ignore-xcodeproj --build-version "$build_version" --generate-git-hash

step "Building universal CLI"
swift build -c release --arch arm64 --arch x86_64 --product aerospace

step "Building AeroSpace.app"
# The log goes in .release/ because that path is gitignored. Writing it anywhere
# else would leave the tree dirty and trip this script's own clean-tree preflight
# on the next run.
rm -rf .release && mkdir -p .release
# CODE_SIGN_IDENTITY="-" is ad-hoc signing, exactly what upstream CI does.
# It avoids needing the self-signed 'aerospace-codesign-certificate' from Keychain.
(
    cd ./xcode
    xcodebuild clean build \
        -scheme AeroSpace \
        -destination "generic/platform=macOS" \
        -configuration Release \
        -derivedDataPath .xcode-build \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="" \
        > ../.release/xcodebuild.log 2>&1 \
        || { tail -40 ../.release/xcodebuild.log; die "xcodebuild failed (full log: .release/xcodebuild.log)"; }
)

########################
### Package          ###
########################

step "Packaging $zip_name"
app_src="xcode/.xcode-build/Build/Products/Release/AeroSpace.app"
cli_src=".build/apple/Products/Release/aerospace"
test -d "$app_src" || die "missing $app_src"
test -f "$cli_src" || die "missing $cli_src"

# .release was already created (and cleared) before the Xcode build, so that the
# build log could land there. Don't wipe it again -- just add the payload dir.
mkdir -p ".release/$zip_root/bin"
cp -r "$app_src" ".release/$zip_root/"
cp "$cli_src" ".release/$zip_root/bin/"
codesign --force --sign - ".release/$zip_root/bin/aerospace"
if test -d legal; then cp -r legal ".release/$zip_root/legal"; fi

# Sanity: both binaries must be universal, and must carry this commit's hash.
# Note: plain `grep >/dev/null` rather than `grep -q`. With `set -o pipefail`,
# `-q` exits on first match, which can SIGPIPE the producer and fail the pipeline
# even though the match succeeded.
check_universal() {
    file "$1" | grep "universal binary with 2 architectures" > /dev/null \
        || die "$1 is not universal"
}
check_universal ".release/$zip_root/AeroSpace.app/Contents/MacOS/AeroSpace"
check_universal ".release/$zip_root/bin/aerospace"
strings ".release/$zip_root/AeroSpace.app/Contents/MacOS/AeroSpace" \
    | grep -F "$(git rev-parse HEAD)" > /dev/null \
    || die "app doesn't contain the current git hash"

(cd .release && zip -qr "$zip_name" "$zip_root")
sha=$(shasum -a 256 ".release/$zip_name" | awk '{print $1}')
echo "sha256: $sha"
echo "size:   $(du -h ".release/$zip_name" | awk '{print $1}')"

if test $dry_run == 1; then
    step "Dry run complete. Built .release/$zip_name; published nothing."
    exit 0
fi

########################
### Publish          ###
########################

step "Creating GitHub release $tag"
gh release create "$tag" ".release/$zip_name" \
    --repo "$REPO" \
    --title "$tag" \
    --notes "Fork of AeroSpace that preserves the tiled layout across macOS native fullscreen.

Built from commit $(git rev-parse HEAD).
Ad-hoc signed, universal binary (arm64 + x86_64).
No man pages or shell completions in this build.

\`\`\`bash
brew install --cask $TAP_SHORT/$CASK_NAME
\`\`\`"

step "Updating the cask"
# Rewrite only the version and sha256 lines; leave the rest of the cask alone.
/usr/bin/sed -i '' \
    -e "s|^  version \".*\"$|  version \"$build_version\"|" \
    -e "s|^  sha256 \".*\"$|  sha256 \"$sha\"|" \
    "$cask_file"
grep -qF "$build_version" "$cask_file" || die "failed to write version into the cask"
grep -qF "$sha" "$cask_file" || die "failed to write sha256 into the cask"
brew style "$cask_file" > /dev/null || die "cask failed brew style"

tap_dir="$(dirname "$(dirname "$cask_file")")"
git -C "$tap_dir" add -A
git -C "$tap_dir" commit -qm "$CASK_NAME $build_version"
git -C "$tap_dir" push -q origin HEAD
echo "pushed cask update to $TAP_REPO"

if test $do_upgrade == 1; then
    step "Upgrading the local install"
    /usr/bin/osascript -e 'quit app "AeroSpace"' 2> /dev/null || true
    sleep 2
    brew upgrade --cask "$CASK_NAME"
    /usr/bin/open -a AeroSpace
fi

step "Released $tag"
echo "https://github.com/$REPO/releases/tag/$tag"
