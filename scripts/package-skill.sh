#!/bin/sh
# Build dist/charm-notes.skill (a zip) from the committed state of this repo,
# for uploading as a skill in claude.ai. Uncommitted changes are NOT included.
set -eu
cd "$(git rev-parse --show-toplevel)"
if ! git diff --quiet HEAD -- 2>/dev/null; then
  echo "note: uncommitted changes exist; packaging HEAD ($(git rev-parse --short HEAD)) only" >&2
fi
mkdir -p dist
git archive --format=zip --prefix=charm-notes/ -o dist/charm-notes.skill HEAD
echo "wrote dist/charm-notes.skill from $(git rev-parse --short HEAD)"
