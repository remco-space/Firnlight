#!/usr/bin/env bash
#
# FR-10.4: refuse to publish anything personal to a particular machine or
# account.
#
# The requirement is not "remember to look" — it is that the repository runs
# the check itself, on every push, wherever it comes from, and never claims
# an enforcement it does not have. Three things run this, and they are the
# same script so they cannot disagree:
#
#   - .githooks/pre-push, which blocks the push on the developer's own
#     machine (see README for the one-line opt-in a fresh clone needs);
#   - the "Personal data check" GitHub Actions workflow
#     (.github/workflows/check-no-personal-data.yml), which runs this script
#     server-side on every push to every branch and every pull request —
#     the actual enforcement, since it needs nothing configured on the
#     pushing machine first and so also covers a fresh clone that skipped
#     the hook opt-in;
#   - a person, by running it directly.
#
# What counts as personal is anything that identifies the developer's machine
# or accounts rather than the project: home-directory paths, private keys,
# provider tokens. What explicitly does *not* count is the project's own
# public-by-design identifiers — the Apple Developer Team ID and the bundle
# identifier are meant to be public and are checked into build settings on
# purpose.
#
# Every pattern below is written so it cannot match its own definition: each
# literal prefix is followed immediately by a character class, and the class's
# opening bracket is not a member of it. That is what lets this file be
# scanned like any other rather than excluded from its own check — an
# exclusion is exactly where a personal path would eventually hide.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# name<TAB>regex<TAB>why
PATTERNS=$(cat <<'PATTERNS'
home directory path (macOS)	/Users/[A-Za-z0-9._-]+	A path under someone's home directory names the machine it was written on.
home directory path (Linux)	/home/[A-Za-z0-9._-]+	A path under someone's home directory names the machine it was written on.
private key	-----BEGIN [A-Z ]*PRIVATE KEY[-]----	A private key must never be published, whatever it unlocks.
GitHub token	gh[pousr]_[A-Za-z0-9]{16,}	A GitHub token grants whatever its owner can do.
GitHub fine-grained token	github_pat_[A-Za-z0-9_]{20,}	A GitHub token grants whatever its owner can do.
AWS access key	AKIA[0-9A-Z]{16}	A cloud access key grants whatever its owner can do.
Slack token	xox[abprs]-[A-Za-z0-9-]{10,}	A Slack token grants whatever its owner can do.
PATTERNS
)

status=0

while IFS=$'\t' read -r name pattern why; do
  [ -n "$name" ] || continue
  # `git grep` searches tracked files only, which is the right scope: the
  # working tree may hold anything, but the repository is what gets
  # published. `-I` skips binaries, where a byte sequence that happens to
  # match is noise rather than a leak.
  # `-e` and not a bare argument: a pattern may begin with "-",
  # which git would otherwise read as an option.
  matches=$(git grep -n -I -E -e "$pattern" || true)
  if [ -n "$matches" ]; then
    status=1
    echo "Personal data check FAILED: $name"
    echo "  Why: $why"
    echo "$matches" | sed 's/^/    /'
    echo
  fi
done <<< "$PATTERNS"

# Files that are personal by their very type, whatever is inside them.
FORBIDDEN_SUFFIXES='\.(p12|pem|key|mobileprovision|provisionprofile|cer|certSigningRequest)$'
forbidden=$(git ls-files | grep -E "$FORBIDDEN_SUFFIXES" || true)
if [ -n "$forbidden" ]; then
  status=1
  echo "Personal data check FAILED: credential or signing file tracked"
  echo "  Why: signing material and keys belong on the machine that owns them, never in a public repository."
  echo "$forbidden" | sed 's/^/    /'
  echo
fi

if [ "$status" -eq 0 ]; then
  echo "Personal data check passed: nothing machine- or account-specific is tracked."
else
  echo "Nothing was pushed. Remove the above, or — if a match is a false positive —"
  echo "change what is written rather than loosening the check."
fi

exit "$status"
