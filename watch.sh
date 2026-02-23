#!/bin/bash
REPO="LinkNavi/Galactica"
WORKFLOWS=(
  "release-poyo.yml"
  "release-airride.yml"
  "release-dreamland.yml"
  "release-ginitrd.yml"
  "release-busybox.yml"
  "release-base-config.yml"
  "build-kernel.yml"
)

while true; do
  clear
  echo "=== Workflow Status ==="
  all_done=true
  for wf in "${WORKFLOWS[@]}"; do
    status=$(gh run list --repo "$REPO" --workflow="$wf" --limit 1 --json status,conclusion \
      --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null)
    printf "  %-30s %s\n" "$wf" "$status"
    [[ "$status" != "completed"* ]] && all_done=false
  done
  echo ""
  $all_done && echo "All done!" && break
  echo "Refreshing in 15s... (Ctrl+C to exit)"
  sleep 15
done
