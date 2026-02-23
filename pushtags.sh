#!/bin/bash
# Run this from your Galactica repo root to create all release tags
# This triggers the GitHub Actions workflows to build and publish the release tarballs

set -e

POYO_VERSION="1.1.0"
AIRRIDE_VERSION="1.0.0"
DREAMLAND_VERSION="1.0.0"
GINITRD_VERSION="1.0.0"
BUSYBOX_VERSION="1.35.0"
BASE_CONFIG_VERSION="1.0.0"
KERNEL_VERSION="6.18.4"

echo "Pushing release tags..."

git tag "poyo-${POYO_VERSION}"            && git push origin "poyo-${POYO_VERSION}"
git tag "airride-${AIRRIDE_VERSION}"      && git push origin "airride-${AIRRIDE_VERSION}"
git tag "dreamland-${DREAMLAND_VERSION}"  && git push origin "dreamland-${DREAMLAND_VERSION}"
git tag "ginitrd-${GINITRD_VERSION}"      && git push origin "ginitrd-${GINITRD_VERSION}"
git tag "busybox-${BUSYBOX_VERSION}"      && git push origin "busybox-${BUSYBOX_VERSION}"
git tag "base-config-${BASE_CONFIG_VERSION}" && git push origin "base-config-${BASE_CONFIG_VERSION}"
git tag "galactica-kernel-${KERNEL_VERSION}" && git push origin "galactica-kernel-${KERNEL_VERSION}"




REPO="LinkNavi/Galactica"

echo "Triggering workflows..."

gh workflow run release-poyo.yml       --repo "$REPO" -f version=1.1.0
gh workflow run release-airride.yml    --repo "$REPO" -f version=1.0.0
gh workflow run release-dreamland.yml  --repo "$REPO" -f version=1.0.0
gh workflow run release-ginitrd.yml    --repo "$REPO" -f version=1.0.0
gh workflow run release-busybox.yml    --repo "$REPO" -f version=1.35.0
gh workflow run release-base-config.yml --repo "$REPO" -f version=1.0.0

echo "Done. Monitor at: https://github.com/LinkNavi/Galactica/actions"
echo "All tags pushed. Monitor workflows at:"
echo "  https://github.com/LinkNavi/Galactica/actions"
