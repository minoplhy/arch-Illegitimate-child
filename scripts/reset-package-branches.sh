#!/usr/bin/env bash
# scripts/reset-package-branches.sh
# One-time utility to reset package branches to pristine upstream AUR history,
# preserving local .pkgconfig and custom repository patches.

set -euo pipefail

BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
PACKAGES_DIR="packages"
PUSH="${PUSH:-false}"

TARGET_PKGS=("$@")
if [ ${#TARGET_PKGS[@]} -eq 0 ]; then
  for p in "${PACKAGES_DIR}"/*; do
    [ -d "$p" ] && TARGET_PKGS+=("$(basename "$p")")
  done
fi

for pkg in "${TARGET_PKGS[@]}"; do
  target_dir="${PACKAGES_DIR}/${pkg}"
  pkgconfig_file="${target_dir}/.pkgconfig"
  
  if [ ! -f "$pkgconfig_file" ]; then
    echo "[SKIP] ${pkg}: No .pkgconfig found."
    continue
  fi

  tracking_mode=$(grep "^TRACKING_MODE=" "$pkgconfig_file" | cut -d'=' -f2 | tr -d '"'\' || true)
  upstream_url=$(grep "^UPSTREAM_URL=" "$pkgconfig_file" | cut -d'=' -f2 | tr -d '"'\' || true)

  # Only reset AUR-tracked packages
  if [ "$tracking_mode" != "aur" ]; then
    echo "[SKIP] ${pkg}: Tracking mode is '${tracking_mode}', skipping."
    continue
  fi

  if [ -z "$upstream_url" ]; then
    upstream_url="https://aur.archlinux.org/${pkg}.git"
  elif [[ ! "$upstream_url" =~ :// ]] && [[ ! "$upstream_url" =~ @ ]]; then
    upstream_url="https://aur.archlinux.org/${upstream_url}.git"
  fi

  echo "=================================================="
  echo "Resetting package: ${pkg}"
  echo "Upstream URL: ${upstream_url}"
  echo "=================================================="

  # 1. Backup .pkgconfig and any local patch commits
  temp_backup=$(mktemp -d)
  cp "$pkgconfig_file" "${temp_backup}/.pkgconfig"

  # Special patch preservation for known patched packages
  has_custom_patch=false
  if [ "$pkg" = "ttf-ms-win11-auto" ]; then
    if git -C "$target_dir" show-ref --verify --quiet refs/heads/ttf-ms-win11-auto; then
      if git -C "$target_dir" log -n 1 --grep="Applied random patch" &>/dev/null; then
        has_custom_patch=true
        git -C "$target_dir" diff HEAD~1 HEAD PKGBUILD > "${temp_backup}/patch.diff" 2>/dev/null || true
      fi
    fi
  fi

  # 2. Fetch upstream AUR
  temp_remote="reset-aur-${pkg}"
  git -C "$target_dir" remote remove "$temp_remote" 2>/dev/null || true
  git -C "$target_dir" remote add "$temp_remote" "$upstream_url"
  git -C "$target_dir" fetch "$temp_remote" --quiet

  remote_branch="master"
  if ! git -C "$target_dir" show-ref --quiet "refs/remotes/${temp_remote}/master"; then
    if git -C "$target_dir" show-ref --quiet "refs/remotes/${temp_remote}/main"; then
      remote_branch="main"
    fi
  fi

  # 3. Hard reset to upstream AUR
  echo "Resetting branch to ${temp_remote}/${remote_branch}..."
  git -C "$target_dir" reset --hard "${temp_remote}/${remote_branch}" --quiet
  git -C "$target_dir" clean -fd --quiet

  # 4. Reapply custom patch if applicable
  if [ "$has_custom_patch" = true ] && [ -s "${temp_backup}/patch.diff" ]; then
    echo "Reapplying custom patch to PKGBUILD..."
    git -C "$target_dir" apply "${temp_backup}/patch.diff" 2>/dev/null || true
    git -C "$target_dir" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
      commit -am "chore: Applied custom repository patch" --quiet || true
  fi

  # 5. Restore .pkgconfig and commit cleanly
  echo "Restoring .pkgconfig..."
  cp "${temp_backup}/.pkgconfig" "${target_dir}/.pkgconfig"
  git -C "$target_dir" add .pkgconfig
  git -C "$target_dir" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
    commit -m "Initialize package config (.pkgconfig) with upstream URL" --quiet

  # Cleanup remote and backup
  git -C "$target_dir" remote remove "$temp_remote"
  rm -rf "$temp_backup"

  echo "Clean linear history created for ${pkg}:"
  git -C "$target_dir" log -n 3 --oneline

  # 6. Force-push to origin if requested
  if [ "$PUSH" = "true" ]; then
    echo "Force-pushing ${pkg} to origin..."
    git -C "$target_dir" push origin "$pkg" --force
  else
    echo "Local reset complete. Run with PUSH=true to push to origin."
  fi
  echo ""
done
