#!/bin/bash
REPO="LinkNavi/Galactica"
WORKFLOWS=(
  "release-poyo.yml"
  "release-airride.yml"
  "release-dreamland.yml"
  "release-ginitrd.yml"
  "release-busybox.yml"
  "release-base-config.yml"
)

for wf in "${WORKFLOWS[@]}"; do
  echo "=== $wf ==="
  run_id=$(gh run list --repo "$REPO" --workflow="$wf" --limit 1 --json databaseId --jq '.[0].databaseId')
  gh run view "$run_id" --repo "$REPO" --log-failed 2>&1 | tail -20
  echo ""
done
