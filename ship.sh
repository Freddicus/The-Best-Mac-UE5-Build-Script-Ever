#!/usr/bin/env bash

# =============================================================================
# LOGGING ARCHITECTURE
#
# This script uses a two-stage file descriptor redirect so that human-facing
# status lines always reach the terminal even after stdout/stderr are
# redirected to the log file.
#
#   Stage 1 (before .env load, see "exec 3>&1 4>&2" below):
#     FD 3 = terminal stdout (original FD 1 saved here)
#     FD 4 = terminal stderr (original FD 2 saved here, reserved)
#
#   Stage 2 (after LOG_FILE is resolved, see "exec >>$LOG_FILE 2>&1" below):
#     FD 1 → log file
#     FD 2 → log file (via FD 1)
#
# After Stage 2:
#   echo "..."        → log file only   (subprocess output, build commands, etc.)
#   echo "..." >&3   → terminal only    (status lines visible to the user)
#
# All helper functions — die(), warn(), good(), info(), error() — write to FD 3
# so their output always appears on the terminal regardless of log redirection.
# =============================================================================

### ============================================================================
### DISPLAY / LOGGING
### ============================================================================

print_log_tail() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "See log file for details: $LOG_FILE" >&3
    if [[ -f "$LOG_FILE" ]]; then
      echo "== Last 20 log lines ==" >&3
      /usr/bin/tail -n 20 "$LOG_FILE" >&3 || true
    fi
  fi
}

die()   { echo "❌ $*" >&3; print_log_tail; exit 1; }
error() { echo "ERROR: $*" >&3; }
warn()  { echo "⚠️  $*" >&3; }
good()  { echo "✅  $*" >&3; }
info()  { echo "== $* ==" >&3; }

on_error_exit() {
  local exit_code=$?
  local fail_line="${BASH_LINENO[0]:-unknown}"
  local fail_cmd="${BASH_COMMAND:-unknown}"
  # Best-effort cleanup for experimental fancy DMG workspace if an error occurs mid-flow.
  if [[ -n "${DMG_MOUNT_DIR:-}" && -d "${DMG_MOUNT_DIR:-}" ]]; then
    /usr/bin/hdiutil detach "${DMG_MOUNT_DIR:-}" >/dev/null 2>&1 || /usr/bin/hdiutil detach -force "${DMG_MOUNT_DIR:-}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DMG_STAGE_DIR:-}" && -d "${DMG_STAGE_DIR:-}" ]]; then
    /bin/rm -rf "${DMG_STAGE_DIR:-}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DMG_RW_PATH:-}" && -f "${DMG_RW_PATH:-}" ]]; then
    /bin/rm -f "${DMG_RW_PATH:-}" >/dev/null 2>&1 || true
  fi
  /bin/rm -f "${_ENTITLEMENTS_TMP:-}" 2>/dev/null || true
  echo "❌ Script failed at line $fail_line (exit $exit_code)" >&3
  echo "Failing command: $fail_cmd" >&3
  print_log_tail
  if [[ "${PRINT_CONFIG:-0}" == "1" ]]; then
    print_config
  fi
  exit "$exit_code"
}

notary_profile_available() {
  /usr/bin/xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1
}

wait_for_notary_profile_with_backoff() {
  local attempt=1
  local delay=1
  while [[ "$attempt" -le 5 ]]; do
    if notary_profile_available; then
      return 0
    fi
    warn "Notary profile not accessible (attempt $attempt/5). Retrying in ${delay}s..."
    /bin/sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
  return 1
}

submit_notary() {
  local path="$1"
  local label="$2"
  local out rc id last_line
  # Capture stdout+stderr without letting set -e abort us on nonzero exit —
  # we need to log the captured output and surface a useful error message.
  if out="$(/usr/bin/xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --no-wait --output-format json 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$out" >&2
  id="$(printf '%s' "$out" | /usr/bin/sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | /usr/bin/head -n 1)"
  if [[ "$rc" -ne 0 || -z "$id" ]]; then
    last_line="$(printf '%s\n' "$out" | /usr/bin/awk 'NF{line=$0} END{print line}')"
    die "Notary submit failed for $label (exit $rc): ${last_line:-no output captured}. Full notarytool output is in the log."
  fi
  echo "Notary submit id ($label): $id" >&3
  echo "$id"
}

notary_wait_with_output() {
  local id="$1"
  local label="$2"
  local out rc last_line

  if out="$(/usr/bin/xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 0
  fi

  rc=$?
  printf '%s\n' "$out" >&2
  last_line="$(printf '%s\n' "$out" | /usr/bin/awk 'NF{line=$0} END{print line}')"
  if [[ -n "$last_line" ]]; then
    warn "notarytool wait failed for ${label}: $last_line"
  else
    warn "notarytool wait failed for ${label} (exit $rc)."
  fi
  return "$rc"
}

wait_notary() {
  local id="$1"
  local label="$2"
  echo "== Notarize ${label} (wait) ==" >&3

  if ! wait_for_notary_profile_with_backoff; then
    die "Notary profile '$NOTARY_PROFILE' is unavailable before wait for ${label}. Resume manually with: /usr/bin/xcrun notarytool wait \"$id\" --keychain-profile \"$NOTARY_PROFILE\""
  fi

  if notary_wait_with_output "$id" "$label"; then
    return 0
  fi

  warn "notarytool wait failed for ${label}. Re-checking notary profile and retrying once."
  if wait_for_notary_profile_with_backoff; then
    if notary_wait_with_output "$id" "$label"; then
      return 0
    fi
  fi

  die "notarytool wait failed for ${label} (submission id: $id). Resume manually with: /usr/bin/xcrun notarytool wait \"$id\" --keychain-profile \"$NOTARY_PROFILE\""
}

set -Eeuo pipefail

# Preserve original stdout/stderr for human-facing status lines (FD 3/4)
exec 3>&1 4>&2

# -----------------------------------------------------------------------------
# Optional .env support
#
# If a `.env` file exists next to this script, load it as environment variables.
# This keeps the main script copy/paste friendly while allowing local configuration
# without editing the script.
#
# Quick usage:
#   - Copy `.env.example` (if provided) to `.env` next to this script
#   - Fill in DEVELOPMENT_TEAM, SIGN_IDENTITY, and (if using Xcode export) EXPORT_PLIST
#   - Run the script
#
# Priority order remains:
#   CLI flags > environment vars (including .env) > defaults in this file
#
# SECURITY NOTE: `.env` is sourced as shell code. Only use a `.env` you trust.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" 2>/dev/null && /bin/pwd -P)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # Safety: refuse to source a .env owned by a different user or world-writable.
  # .env is sourced as shell code, so a tampered file is a trivial privilege escalation.
  _env_owner="$(/usr/bin/stat -f "%Su" "$ENV_FILE" 2>/dev/null || true)"
  _env_mode="$(/usr/bin/stat -f "%p" "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$_env_owner" && "$_env_owner" != "$(/usr/bin/id -un)" ]]; then
    die ".env is owned by '$_env_owner', not the current user. Refusing to source it: $ENV_FILE"
  fi
  if [[ -n "$_env_mode" && $(( _env_mode & 0002 )) -ne 0 ]]; then
    die ".env is world-writable. Fix with: chmod o-w \"$ENV_FILE\""
  fi
  unset _env_owner _env_mode
  # Export variables defined in .env so they behave like real environment variables.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  info "Loaded .env: $ENV_FILE"
fi

### ============================================================================
### CONFIGURATION
###
### This script is configured via:
###   - .env (next to the script)
###   - environment variables
###   - CLI flags (highest priority)
###
### Do not edit this script to set configuration values.
### ============================================================================

### ============================================================================
### INTERNALS
### ============================================================================

is_placeholder() {
  # Treat empty/unset as "not configured".
  # We intentionally do NOT support magic placeholder strings anymore.
  local v="${1:-}"
  [[ -z "$v" ]]
}


require_not_placeholder() {
  local name="$1"; local value="$2"; local hint="$3"
  if is_placeholder "$value"; then
    if [[ "${PRINT_CONFIG:-0}" == "1" ]]; then
      print_config
    fi
    die "$name is not configured. Set it via .env / environment variable, or provide a CLI flag. Hint: $hint"
  fi
}

_maybe_prompt_for_asc_upload() {
  # Interactive "upload this artifact to App Store Connect?" prompt, shared
  # by the iOS IPA and Mac App Store .pkg pipelines. Returns 0 if the user
  # assents (TTY + y/Y), 1 otherwise. Skips silently on non-TTY (CI runs).
  #
  # Caller checks the explicit upload flag first — if the user passed
  # --mas-upload-app / --ios-upload-ipa, no prompt fires (flag wins). The
  # prompt is only an offer for the case where the user opted into
  # validation but hadn't committed to upload yet.
  #   $1 = artifact path (used only for the prompt label's extension)
  local artifact="$1"
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local ext="${artifact##*.}"
  local ans
  read -r -p "Upload this .${ext} to App Store Connect now? (y/N) " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Helpers for config discovery / printing
# -----------------------------------------------------------------------------

read_uproject_module_name() {
  # Extract the first module name from a .uproject (JSON) without python/jq.
  # This is a best-effort parser designed for typical Unreal .uproject formatting.
  #
  # It looks for: "Modules": [ { "Name": "YourModule", ... }, ... ]
  local uproject_path="$1"
  [[ -f "$uproject_path" ]] || { echo ""; return 0; }

  /usr/bin/awk '
    BEGIN {
      in_modules = 0
      bracket_depth = 0
    }

    # Once we enter the Modules array, track [] depth so we know when it ends.
    {
      line = $0
    }

    # Enter Modules section when we see "Modules"
    !in_modules && line ~ /"Modules"[[:space:]]*:/ {
      in_modules = 1
    }

    # If we are in Modules, update bracket depth for [ and ] on this line.
    in_modules {
      # Count [ and ] occurrences (simple but effective for .uproject files)
      open = gsub(/\[/, "[", line)
      close = gsub(/\]/, "]", line)
      bracket_depth += (open - close)

      # Look for the first "Name": "..."
      # Capture the first quoted string after "Name":
      if (match(line, /"Name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^.*"Name"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/".*$/, "", s)
        print s
        exit 0
      }

      # If bracket_depth drops to 0 or below, we have left the array.
      # (In practice, it should be 0 at the end of the array.)
      if (bracket_depth <= 0) {
        exit 0
      }
    }

    END { }
  ' "$uproject_path" 2>/dev/null || true
}

autodetect_uproject_if_needed() {
  if [[ -n "${UPROJECT_PATH:-}" ]]; then
    if [[ -f "$UPROJECT_PATH" ]]; then
      UPROJECT_NAME="$(/usr/bin/basename "$UPROJECT_PATH")"
      return 0
    fi
    die "UPROJECT_PATH set but not found: $UPROJECT_PATH"
  fi

  if is_placeholder "${UPROJECT_NAME:-}"; then
    local found=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && found+=("$line")
    done < <(/usr/bin/find "$REPO_ROOT" -maxdepth 1 -type f -name '*.uproject' 2>/dev/null)

    if [[ "${#found[@]}" -eq 1 ]]; then
      UPROJECT_PATH="${found[0]}"
      UPROJECT_NAME="$(/usr/bin/basename "$UPROJECT_PATH")"
      info "Auto-detected .uproject: $UPROJECT_NAME"
    elif [[ "${#found[@]}" -gt 1 ]]; then
      echo "Found multiple .uproject candidates:" >&3
      printf '  - %s\n' "${found[@]}" >&3
      die "Multiple .uproject files found. Pass --uproject explicitly."
    else
      die "No .uproject found in REPO_ROOT. Put the script in the project root or pass --repo-root."
    fi
  fi
}

autodetect_names_if_needed() {
  local base
  base="${UPROJECT_NAME%.uproject}"

  if is_placeholder "${LONG_NAME:-}"; then
    LONG_NAME="$base"
    info "Auto-detected LONG_NAME: $LONG_NAME"
  fi

  if is_placeholder "${SHORT_NAME:-}"; then
    SHORT_NAME="$base"
    SHORT_NAME="${SHORT_NAME// /}"  # conservative
    info "Auto-detected SHORT_NAME: $SHORT_NAME"
  fi
}

autodetect_workspace_guess_if_needed() {
  # If workspace is placeholder, try Unreal's common naming convention: "<Project> (Mac).xcworkspace".
  if [[ "$USE_XCODE_EXPORT" == "1" ]] && is_placeholder "$XCODE_WORKSPACE"; then
    local base guess
    base="${UPROJECT_NAME%.uproject}"
    guess="$REPO_ROOT/${base} (Mac).xcworkspace"
    if [[ -d "$guess" ]]; then
      XCODE_WORKSPACE="$(/usr/bin/basename "$guess")"
      WORKSPACE="$guess"
      info "Auto-detected workspace by convention: $WORKSPACE"
    fi
  fi
}


seed_apple_launchscreen_compat() {
  # Defensively place a pre-compiled LaunchScreen.storyboardc at
  # $(Project)/Build/Apple/Resources/Interface/LaunchScreen.storyboardc by
  # copying the engine's stock one from
  # $(UE)/Engine/Build/IOS/Resources/Interface/LaunchScreen.storyboardc.
  #
  # Why: XcodeProject.cs::ProcessAssets walks a path priority list for the
  # launch storyboard at GenerateProjectFiles time. Pre-our-fix, Mac was
  # hitting the engine's pre-compiled iOS .storyboardc fallback — Xcode
  # treats .storyboardc as a wrapper bundle and ships it as-is, so the build
  # worked. The moment a consumer drops a custom
  #   $(Project)/Build/IOS/Resources/Interface/LaunchScreen.storyboard
  # source file (a normal way to override the iOS launch screen), Mac now
  # hits the .storyboard source first and tries to compile an iOS storyboard
  # for macOS — which fails. The engine's AddResource call is unconditional;
  # there's no engine-level switch. The fix lives at the project layer:
  # provide a Mac-platform-shared override (.storyboardc, already compiled)
  # that wins earlier in the priority list, so Mac never reaches the
  # hardcoded iOS .storyboard line.
  #
  # Idempotent: skips if the destination already exists (consumer-owned) or
  # the engine source is missing (older UE versions / partial installs).
  # This is the one exception to "ship.sh does not write under Build/" —
  # the file we drop here is a stock engine asset, not a customization, and
  # it's fine to commit it to the project repo afterwards.
  [[ "${SEED_APPLE_LAUNCHSCREEN_COMPAT:-1}" == "1" ]] || { info "Skipping Apple LaunchScreen.storyboardc seed (SEED_APPLE_LAUNCHSCREEN_COMPAT=0)"; return 0; }

  local src dst_dir dst
  src="$UE_ROOT/Engine/Build/IOS/Resources/Interface/LaunchScreen.storyboardc"
  dst_dir="$REPO_ROOT/Build/Apple/Resources/Interface"
  dst="$dst_dir/LaunchScreen.storyboardc"

  if [[ -e "$dst" ]]; then
    info "Apple LaunchScreen.storyboardc already present — skipping seed: $dst"
    return 0
  fi

  if [[ ! -d "$src" ]]; then
    warn "Engine LaunchScreen.storyboardc not found at $src — skipping Apple compat seed"
    return 0
  fi

  /bin/mkdir -p "$dst_dir"
  /bin/cp -R "$src" "$dst"
  good "Seeded $dst from engine fallback (commit it; prevents Mac from compiling an iOS .storyboard source)"
}

regenerate_project_files() {
  # Regenerate the consumer's Xcode workspace via UE's GenerateProjectFiles.sh.
  # UBT bakes resolved absolute paths from Build/{Platform}/Resources/ into
  # Intermediate/ProjectFilesMac/<Project> (Mac).xcodeproj/project.pbxproj at
  # project-file-generation time, NOT at xcodebuild time. Adding/removing a
  # sibling file there (e.g. a custom LaunchScreen.storyboard) does not flow
  # into the build until project files are regenerated. Cheap and idempotent.
  [[ "$USE_XCODE_EXPORT" == "1" ]] || return 0
  [[ "${REGEN_PROJECT_FILES:-1}" == "1" ]] || { info "Skipping GenerateProjectFiles (REGEN_PROJECT_FILES=0)"; return 0; }

  local gen_script
  gen_script="$UE_ROOT/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh"

  if [[ ! -x "$gen_script" ]]; then
    warn "GenerateProjectFiles.sh not executable, skipping regen: $gen_script"
    return 0
  fi

  info "Regenerating Xcode project files (GenerateProjectFiles.sh)"
  "$gen_script" -project="$UPROJECT_PATH" -game
  good "Project files regenerated."
}

choose_from_list_interactively() {
  # Prompt user to choose a numbered item from an array.
  # Args: prompt, default_index (1-based), array...
  local prompt="$1"
  local default_idx="$2"
  shift 2
  local items=("$@")

  if [[ ! -t 0 ]]; then
    echo ""; return 1
  fi

  local choice
  read -r -p "$prompt [$default_idx]: " choice
  choice="${choice:-$default_idx}"

  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#items[@]}" ]]; then
    echo "${items[$((choice-1))]}"
    return 0
  fi

  echo ""; return 1
}

autodetect_export_plist_if_needed() {
  # If EXPORT_PLIST is placeholder, try to locate an ExportOptions.plist in the repo root.
  # Heuristic: a candidate plist contains destination=export, e.g.
  #   <key>destination</key><string>export</string>
  # (whitespace/newlines allowed).
  if ! is_placeholder "$EXPORT_PLIST"; then
    return 0
  fi

  # Fast path: conventional name.
  local conventional="$REPO_ROOT/ExportOptions.plist"
  if [[ -f "$conventional" ]]; then
    EXPORT_PLIST="$conventional"
    info "Auto-detected ExportOptions.plist (by name): $EXPORT_PLIST"
    return 0
  fi

  # Scan all *.plist in the repo root and look for destination=export.
  local matches=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue

    # Collapse whitespace to make matching resilient to formatting.
    # We intentionally avoid plutil parsing to keep dependencies minimal.
    if /bin/cat "$p" 2>/dev/null | /usr/bin/tr -d '[:space:]' | /usr/bin/grep -qi '<key>destination</key><string>export</string>'; then
      matches+=("$p")
      continue
    fi

    # Some plists may use <key>method</key> etc. We only care about destination.
  done < <(/usr/bin/find "$REPO_ROOT" -maxdepth 1 -type f -name '*.plist' 2>/dev/null | /usr/bin/sort)

  if [[ "${#matches[@]}" -eq 1 ]]; then
    EXPORT_PLIST="${matches[0]}"
    info "Auto-detected ExportOptions.plist (by contents): $EXPORT_PLIST"
    return 0
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    echo "== EXPORT_PLIST not set — found multiple ExportOptions-like plist candidates in repo root ==" >&3
    local i=1
    for p in "${matches[@]}"; do
      echo "  [$i] $p" >&3
      i=$((i+1))
    done

    # If running in a non-interactive context, don't guess.
    if [[ ! -t 0 ]]; then
      warn "Multiple ExportOptions-like plist files found. Pass --export-plist PATH (or set EXPORT_PLIST env var) to select one."
      return 0
    fi

    local choice
    read -r -p "Select ExportOptions.plist [1]: " choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#matches[@]}" ]]; then
      EXPORT_PLIST="${matches[$((choice-1))]}"
      info "Selected ExportOptions.plist: $EXPORT_PLIST"
      return 0
    fi

    warn "Invalid selection '$choice'. Provide --export-plist PATH instead."
    return 0
  fi

  # No match found; offer to generate one interactively.
  maybe_generate_export_plist_interactively || true
}

maybe_generate_export_plist_interactively() {
  # Offer to generate a minimal ExportOptions.plist suitable for Developer ID exports.
  # Only runs in interactive terminals.
  # Uses DEVELOPMENT_TEAM for teamID.

  if [[ ! -t 0 ]]; then
    return 1
  fi

  local out
  out="$REPO_ROOT/ExportOptions.plist"

  echo "No ExportOptions.plist was detected." >&3
  echo "I can generate a minimal one for Developer ID exports." >&3
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "Team ID: $DEVELOPMENT_TEAM" >&3
  else
    echo "Team ID: (not set)" >&3
  fi

  local ans
  read -r -p "Generate ExportOptions.plist at '$out'? (Y/n) " ans
  if [[ "${ans:-Y}" =~ ^[Nn]$ ]]; then
    return 1
  fi

  if [[ -f "$out" ]]; then
    local ow
    read -r -p "File already exists. Overwrite? (y/N) " ow
    if [[ ! "${ow:-N}" =~ ^[Yy]$ ]]; then
      return 1
    fi
  fi

  info "Generating ExportOptions.plist: $out"
  /bin/cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
</dict>
</plist>
PLIST

  # Point the script at the generated file.
  EXPORT_PLIST="$out"
  return 0
}


sanitize_name_for_tmp() {
  # mktemp's -t template is happier without spaces/special chars.
  local v="$1"
  v="${v// /_}"
  v="${v//[^a-zA-Z0-9._-]/_}"
  echo "$v"
}

# -----------------------------------------------------------------------------
# UE Apple_SDK.json Xcode version compatibility check (best-effort warning)
# -----------------------------------------------------------------------------
normalize_semver_3() {
  # Normalize a version string to MAJOR.MINOR.PATCH (missing parts default to 0).
  # Examples:
  #   15      -> 15.0.0
  #   15.2    -> 15.2.0
  #   15.2.1  -> 15.2.1
  local v="${1:-}"
  [[ -n "$v" ]] || { echo ""; return 0; }

  local major minor patch
  major="${v%%.*}"
  if [[ "$v" == *.* ]]; then
    minor="${v#*.}"; minor="${minor%%.*}"
  else
    minor="0"
  fi
  if [[ "$v" == *.*.* ]]; then
    patch="${v#*.*.}"
  else
    patch="0"
  fi

  echo "${major:-0}.${minor:-0}.${patch:-0}"
}

semver3_to_int() {
  # Convert MAJOR.MINOR.PATCH to a comparable integer.
  # Assumes each component < 1000.
  local v
  v="$(normalize_semver_3 "${1:-}")"
  [[ -n "$v" ]] || { echo ""; return 0; }

  local a b c
  a="${v%%.*}"
  b="${v#*.}"; b="${b%%.*}"
  c="${v##*.}"

  echo $((a*1000000 + b*1000 + c))
}

bump_semver() {
  # Bump a semver string (X.Y.Z or vX.Y.Z) by major, minor, or patch.
  # Outputs the bumped version, preserving a leading "v" if present.
  # Lower components are reset to 0 on major/minor bumps.
  local component="$1" version="$2"
  local prefix="" rest major minor patch
  if [[ "$version" == v* ]]; then
    prefix="v"
    rest="${version#v}"
  else
    rest="$version"
  fi
  if ! [[ "$rest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "--bump-$component: '$version' is not a valid semver (expected X.Y.Z or vX.Y.Z)"
  fi
  IFS='.' read -r major minor patch <<< "$rest"
  case "$component" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  echo "${prefix}${major}.${minor}.${patch}"
}

extract_json_string_value() {
  # Best-effort extraction of a top-level JSON string field value.
  # Example: extract_json_string_value file.json MinVersion
  local file="$1"; local key="$2"
  [[ -f "$file" ]] || { echo ""; return 0; }

  /usr/bin/grep -E "\"${key}\"[[:space:]]*:[[:space:]]*\"" "$file" 2>/dev/null \
    | /usr/bin/head -n 1 \
    | /usr/bin/sed -E 's/.*"'"$key"'\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/' \
    || true
}

extract_json_array_lines() {
  # Extract raw lines between "AppleVersionToLLVMVersions" [ ... ] as a single stream.
  local file="$1"
  [[ -f "$file" ]] || { return 0; }

  /usr/bin/awk '
    BEGIN{in=0}
    /"AppleVersionToLLVMVersions"[[:space:]]*:/ {in=1}
    in {print}
    in && /\]/ {exit}
  ' "$file" 2>/dev/null || true
}

get_installed_xcode_version() {
  # Returns Xcode version like 15.2 or empty.
  local line
  line="$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/head -n 1 || true)"
  # Expected: "Xcode 15.2"
  echo "$line" | /usr/bin/awk '{print $2}' 2>/dev/null || true
}

get_local_swift_branch() {
  # Returns the major.minor of the active Swift toolchain (e.g. "6.3"), which
  # doubles as the branch suffix for apple/llvm-project's swift/release/X.Y
  # convention. Empty on failure. Drives the LLVM version lookup below.
  local line
  line="$(/usr/bin/xcrun swift --version 2>/dev/null | /usr/bin/head -n 1 || true)"
  # Expected: "swift-driver version: ... Apple Swift version 6.3.2 (...)"
  echo "$line" | /usr/bin/awk -F'Apple Swift version ' '
    NF>1 { split($2, a, "."); if (a[1] && a[2]) print a[1] "." a[2]; exit }'
}

fetch_llvm_version_from_apple_source() {
  # $1 = Swift branch suffix (e.g. "6.3"). Prints the upstream LLVM version
  # (X.Y.Z) that this Swift release is based on, sourced from Apple's own
  # version-definition file in apple/llvm-project. Empty + non-zero on failure.
  #
  # File location differs across branches:
  #   - swift/release/6.1+  →  cmake/Modules/LLVMVersion.cmake
  #   - swift/release/6.0-  →  llvm/CMakeLists.txt (inline set() calls)
  local swift_branch="$1"
  [[ -n "$swift_branch" ]] || return 1
  command -v /usr/bin/curl &>/dev/null || return 1

  local base="https://raw.githubusercontent.com/apple/llvm-project/swift/release/${swift_branch}"
  local path content major minor patch
  for path in "cmake/Modules/LLVMVersion.cmake" "llvm/CMakeLists.txt"; do
    content="$(/usr/bin/curl --silent --location --fail --max-time 15 "$base/$path" 2>/dev/null || true)"
    [[ -n "$content" ]] || continue
    major="$(echo "$content" | /usr/bin/grep -oE 'set\(LLVM_VERSION_MAJOR [0-9]+' | /usr/bin/awk '{print $2}')"
    minor="$(echo "$content" | /usr/bin/grep -oE 'set\(LLVM_VERSION_MINOR [0-9]+' | /usr/bin/awk '{print $2}')"
    patch="$(echo "$content" | /usr/bin/grep -oE 'set\(LLVM_VERSION_PATCH [0-9]+' | /usr/bin/awk '{print $2}')"
    if [[ -n "$major" && -n "$minor" && -n "$patch" ]]; then
      echo "$major.$minor.$patch"
      return 0
    fi
  done
  return 1
}

patch_apple_sdk_json() {
  # $1 = path to Apple_SDK.json, $2 = xcode version (X.Y.Z), $3 = LLVM version (X.Y.Z)
  # Prints exactly one of: ok | ok_maxv | already_present | parse_failed | error
  # ("ok_maxv" means the entry was added AND MaxVersion was bumped.)
  local json="$1" xcode_norm="$2" llvm_ver="$3"
  command -v python3 &>/dev/null || { echo "error"; return 1; }
  local result
  result="$(python3 - "$json" "$xcode_norm" "$llvm_ver" <<'PYEOF' 2>/dev/null
import sys, re
try:
    json_file, xcode_norm, llvm_ver = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(json_file, "r") as f:
        content = f.read()

    new_entry = '"' + xcode_norm + '-' + llvm_ver + '"'
    if new_entry in content:
        print("already_present"); sys.exit(0)

    m = re.search(r'("AppleVersionToLLVMVersions"\s*:\s*\[)(.*?)(\s*\])', content, re.DOTALL)
    if not m:
        print("parse_failed"); sys.exit(0)

    array_body = m.group(2)
    last_entries = re.findall(r'"[\d.]+-[\d.]+"', array_body)
    if not last_entries:
        print("parse_failed"); sys.exit(0)

    last_entry = last_entries[-1]
    last_pos = array_body.rfind(last_entry)
    indent_m = re.search(r'\n([\t ]+)"[\d.]+-[\d.]+"', array_body)
    indent = indent_m.group(1) if indent_m else "\t\t"

    insert_at = last_pos + len(last_entry)
    new_body = array_body[:insert_at] + ",\n" + indent + new_entry + array_body[insert_at:]
    new_content = content[:m.start()] + m.group(1) + new_body + m.group(3) + content[m.end():]

    def sv(v):
        try: return tuple(int(x) for x in v.split("."))
        except: return (0,)

    bumped = False
    mx = re.search(r'"MaxVersion"\s*:\s*"([^"]+)"', new_content)
    if mx and sv(xcode_norm) > sv(mx.group(1)):
        new_content = new_content[:mx.start(1)] + xcode_norm + new_content[mx.end(1):]
        bumped = True

    with open(json_file, "w") as f:
        f.write(new_content)

    print("ok_maxv" if bumped else "ok")
except Exception:
    print("error"); sys.exit(0)
PYEOF
)" || result="error"
  # Empty stdout (e.g. interpreter crashed before any print) is also a failure.
  echo "${result:-error}"
}

check_apple_sdk_json_compat() {
  # NOTE: Apple_SDK.json describes supported Xcode versions for this UE install.
  # It does NOT describe macOS versions.

  local json="$UE_ROOT/Engine/Config/Apple/Apple_SDK.json"
  if [[ ! -f "$json" ]]; then
    info "Apple_SDK.json not found — skipping UE/Xcode compatibility check"
    return 0
  fi

  local xcode_ver
  xcode_ver="$(get_installed_xcode_version)"
  if [[ -z "$xcode_ver" ]]; then
    info "Xcode not detected — skipping UE/Xcode compatibility check"
    return 0
  fi

  local xcode_norm
  xcode_norm="$(normalize_semver_3 "$xcode_ver")"
  info "Detected Xcode version: $xcode_norm"

  local minv maxv
  minv="$(extract_json_string_value "$json" "MinVersion")"
  maxv="$(extract_json_string_value "$json" "MaxVersion")"

  local x_i min_i max_i
  x_i="$(semver3_to_int "$xcode_ver")"
  min_i="$(semver3_to_int "$minv")"
  max_i="$(semver3_to_int "$maxv")"

  if [[ -n "$minv" && -n "$maxv" ]]; then
    good "UE Apple_SDK.json Min/Max: $(normalize_semver_3 "$minv") .. $(normalize_semver_3 "$maxv")"
  else
    warn "UE Apple_SDK.json does not specify a MinVersion/MaxVersion"
  fi

  info "Checking Xcode version against AppleVersionToLLVMVersions mappings"

  # 1) Range check: MinVersion <= Xcode <= MaxVersion
  local range_ok=1
  if [[ -n "$min_i" && -n "$x_i" && "$x_i" -lt "$min_i" ]]; then
    range_ok=0
  fi
  if [[ -n "$max_i" && -n "$x_i" && "$x_i" -gt "$max_i" ]]; then
    range_ok=0
  fi

  # 2) Mapping check: Xcode version appears in AppleVersionToLLVMVersions mappings.
  # Be defensive here: malformed JSON should not kill the script.
  local errexit_was_set=0
  if [[ $- == *e* ]]; then
    errexit_was_set=1
    set +e
  fi

  local map_ok=0
  local parse_issue=0

  # Pull out quoted pairs like "16.0.0-17.0.6" (Xcode -> LLVM) from the whole file.
  local ranges=()
  local r
  while IFS= read -r r; do
    r="${r%\"}"; r="${r#\"}"
    if [[ "$r" == *-* && "$r" == *.*.*-*.*.* ]]; then
      ranges+=("$r")
    fi
  done < <(/usr/bin/grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+\.[0-9]+"' "$json" 2>/dev/null || true)

  if [[ "${#ranges[@]}" -eq 0 ]]; then
    parse_issue=1
    error "Could not parse any AppleVersionToLLVMVersions entries from $json (mapping check skipped)."
    map_ok=1
  else
    good "Found ${#ranges[@]} AppleVersionToLLVMVersions entries."
  fi

  local start
  for r in "${ranges[@]}"; do
    start="${r%%-*}"
    # Apple_SDK.json entries are "XcodeVersion-LLVMVersion" mappings.
    # (The LLVM version after the dash is extracted implicitly; only start is validated here.)
    if [[ -n "$start" && -n "$xcode_norm" && "$start" == "$xcode_norm" ]]; then
      map_ok=1
      break
    fi
  done

  if [[ $errexit_was_set -eq 1 ]]; then
    set -e
  fi

  if [[ "$range_ok" -eq 0 || "$map_ok" -eq 0 ]]; then
    error "Xcode compatibility check FAILED. This WILL cause build failures with this UE install."
    error "UE_ROOT: $UE_ROOT"
    error "Apple SDK policy file: $json"
    error "Detected Xcode: $xcode_norm"
    if [[ -n "$minv" && -n "$maxv" ]]; then
      error "Supported Xcode range (per Apple_SDK.json): $(normalize_semver_3 "$minv") .. $(normalize_semver_3 "$maxv")"
    fi
    if [[ "$range_ok" -eq 0 ]]; then
      error "Detected Xcode is outside MinVersion/MaxVersion."
    fi
    if [[ "$map_ok" -eq 0 ]]; then
      error "AppleVersionToLLVMVersions does not include this Xcode version."
    fi
    local yn=""
    # Auto-patch needs: (a) curl + the active Swift toolchain (for the lookup),
    # and (b) python3 (for the JSON edit). Only offer when all are present.
    local swift_branch=""
    swift_branch="$(get_local_swift_branch || true)"
    if [[ -t 3 ]] && [[ -n "$swift_branch" ]] && command -v python3 &>/dev/null; then
      printf "Auto-patch Apple_SDK.json using Apple's own LLVM version source\n" >&3
      printf "(github.com/apple/llvm-project, branch swift/release/%s)? [y/N] " "$swift_branch" >&3
      read -r yn || yn=""
    fi
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      info "Fetching LLVM version from apple/llvm-project (swift/release/$swift_branch)..."
      local llvm_ver=""
      llvm_ver="$(fetch_llvm_version_from_apple_source "$swift_branch")" || true
      if [[ -z "$llvm_ver" ]]; then
        error "Could not fetch LLVM version from apple/llvm-project for Swift $swift_branch."
        error "The swift/release/$swift_branch branch may not exist yet (beta Xcode?), or"
        error "the version-file layout has changed. Check manually:"
        error "  https://github.com/apple/llvm-project/tree/swift/release/$swift_branch"
        die "Xcode/UE toolchain policy mismatch. Update Apple_SDK.json manually and re-run."
      fi
      good "Apple source: Swift $swift_branch -> LLVM $llvm_ver"
      local patch_result
      patch_result="$(patch_apple_sdk_json "$json" "$xcode_norm" "$llvm_ver")"
      case "$patch_result" in
        ok)
          good "Patched Apple_SDK.json: added \"$xcode_norm-$llvm_ver\"." ;;
        ok_maxv)
          good "Patched Apple_SDK.json: added \"$xcode_norm-$llvm_ver\" and bumped MaxVersion to $xcode_norm." ;;
        already_present)
          good "Mapping entry already present in Apple_SDK.json — no change needed." ;;
        *)
          error "Failed to patch Apple_SDK.json (result: ${patch_result:-empty})."
          die "Xcode/UE toolchain policy mismatch. Update Apple_SDK.json manually and re-run." ;;
      esac
      return 0
    fi
    error "Fix: edit $json"
    error "  - If needed, update MinVersion/MaxVersion to include $(normalize_semver_3 "$xcode_ver")"
    error "  - Add a mapping entry that covers your Xcode version, e.g.:"
    error "      \"$(normalize_semver_3 "$xcode_ver")-<LLVM_VERSION>\""
    error "    (Use the LLVM version that ships with your Xcode toolchain.)"
    error "    Version mapping can be found at https://en.wikipedia.org/wiki/Xcode#Toolchain_versions"
    die "Xcode/UE toolchain policy mismatch. Update Apple_SDK.json and re-run."
  fi

  if [[ "$range_ok" -eq 1 ]]; then
    good "Xcode version is within MinVersion/MaxVersion."
  fi
  if [[ "$map_ok" -eq 1 && "$parse_issue" -eq 0 ]]; then
    good "Xcode version is covered by AppleVersionToLLVMVersions."
  fi
}

print_config() {
  echo "== Resolved configuration ==" >&3
  echo "MAC_DISTRIBUTION:  $MAC_DISTRIBUTION (developer-id | app-store | off)" >&3
  echo "IOS_DISTRIBUTION:  $IOS_DISTRIBUTION (off | app-store)" >&3
  echo "REPO_ROOT:         $REPO_ROOT" >&3
  echo "UPROJECT_PATH:     $UPROJECT_PATH" >&3
  echo "UE_ROOT:           $UE_ROOT" >&3
  echo "UAT (RunUAT.sh):   $SCRIPTS/RunUAT.sh" >&3
  echo "UE_EDITOR:         $UE_EDITOR" >&3
  echo "BUILD_DIR:         $BUILD_DIR" >&3
  echo "UAT_ARCHIVE_DIR:   ${UAT_ARCHIVE_DIR:-<derived from BUILD_DIR>}" >&3
  echo "LOG_DIR:           $LOG_DIR" >&3
  echo "SHORT_NAME:        $SHORT_NAME" >&3
  echo "LONG_NAME:         $LONG_NAME" >&3
  echo "USE_XCODE_EXPORT:  $USE_XCODE_EXPORT" >&3
  echo "REGEN_PROJECT_FILES: $REGEN_PROJECT_FILES" >&3
  echo "SEED_APPLE_LAUNCHSCREEN_COMPAT: $SEED_APPLE_LAUNCHSCREEN_COMPAT" >&3
  echo "SEED_MAC_INFO_TEMPLATE_PLIST:   $SEED_MAC_INFO_TEMPLATE_PLIST" >&3
  echo "USE_UE_PACKAGE_VERSION_COUNTER: $USE_UE_PACKAGE_VERSION_COUNTER (0=Path B auto-bump default, 1=Path A UE-canonical)" >&3
  echo "CLEAN_BUILD_DIR:   $CLEAN_BUILD_DIR" >&3
  echo "DRY_RUN:           $DRY_RUN" >&3
  echo "PRINT_CONFIG:      $PRINT_CONFIG" >&3
  echo "NOTARIZE:          ${NOTARIZE:-<unset>}" >&3
  echo "ENABLE_STEAM:      $ENABLE_STEAM" >&3
  echo "WRITE_STEAM_APPID: $WRITE_STEAM_APPID" >&3
  echo "MACOS_APPICON_SET_NAME: ${MACOS_APPICON_SET_NAME:-<unset, mirror auto-detects first appiconset in Build/Mac/Resources/Assets.xcassets>}" >&3
  echo "ENABLE_IOS:        ${ENABLE_IOS:-0}" >&3
  echo "IOS_ONLY:          ${IOS_ONLY:-0}" >&3
  if [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
    echo "MAS_EXPORT_PLIST:  ${MAS_EXPORT_PLIST:-<unset>}" >&3
    echo "MAS_ASC_VALIDATE:  ${MAS_ASC_VALIDATE:-0}" >&3
    echo "MAS_ASC_UPLOAD:    ${MAS_ASC_UPLOAD:-0}" >&3
  fi
  if [[ "${ENABLE_IOS:-0}" == "1" ]]; then
    echo "IOS_WORKSPACE:     ${IOS_WORKSPACE:-<unset>}" >&3
    echo "IOS_SCHEME:        ${IOS_SCHEME:-<unset>}" >&3
    echo "IOS_EXPORT_PLIST:  ${IOS_EXPORT_PLIST:-<unset>}" >&3
    echo "IOS_APPICON_SET_NAME: ${IOS_APPICON_SET_NAME:-<unset, mirror auto-detects first appiconset in Build/IOS/Resources/Assets.xcassets>}" >&3
    echo "IOS_MARKETING_VERSION: ${IOS_MARKETING_VERSION:-<unset, inherits MARKETING_VERSION>}" >&3
    echo "IOS_ASC_VALIDATE:  ${IOS_ASC_VALIDATE:-0}" >&3
    echo "IOS_ASC_UPLOAD:    ${IOS_ASC_UPLOAD:-0}" >&3
  fi
  if [[ "${IOS_ASC_VALIDATE:-0}" == "1" || "${IOS_ASC_UPLOAD:-0}" == "1" || "${MAS_ASC_VALIDATE:-0}" == "1" || "${MAS_ASC_UPLOAD:-0}" == "1" ]]; then
    echo "ASC_API_KEY_ID:    ${ASC_API_KEY_ID:-<unset>} (shared by iOS + MAS uploads)" >&3
    echo "ASC_API_ISSUER:    ${ASC_API_ISSUER:-<unset>}" >&3
    echo "ASC_API_KEY_PATH:  ${ASC_API_KEY_PATH:-<unset>}" >&3
  fi
  echo "ENABLE_ZIP:        ${ENABLE_ZIP:-<unset>}" >&3
  echo "ENABLE_DMG:        $ENABLE_DMG" >&3
  echo "FANCY_DMG:         $FANCY_DMG" >&3
  echo "DMG_NAME:          ${DMG_NAME:-<unset>}" >&3
  echo "DMG_VOLUME_NAME:   ${DMG_VOLUME_NAME:-<unset>}" >&3
  echo "DMG_OUTPUT_DIR:    ${DMG_OUTPUT_DIR:-<unset>}" >&3
  echo "VERSION_MODE:      $VERSION_MODE" >&3
  if [[ "$VERSION_MODE" != "NONE" ]]; then
    echo "VERSION_CONTENT_DIR: $VERSION_CONTENT_DIR" >&3
    echo "VERSION_FILE:      $REPO_ROOT/Content/$VERSION_CONTENT_DIR/version.txt" >&3
  fi
  echo "MARKETING_VERSION: ${MARKETING_VERSION:-<unset, leaves DefaultEngine.ini VersionInfo untouched>}" >&3
  echo "ENABLE_GAME_MODE:  ${ENABLE_GAME_MODE:-<unset, leaves Info.Template.plist GameMode keys untouched>}" >&3
  echo "ENABLE_GAME_CENTER: ${ENABLE_GAME_CENTER:-<unset, leaves Game Center entitlements alone>} (1=add, 0=remove com.apple.developer.game-center; eligible channels: IOS_DISTRIBUTION=app-store and MAC_DISTRIBUTION=app-store)" >&3
  echo "APP_CATEGORY:      ${APP_CATEGORY:-<unset, leaves DefaultEngine.ini AppCategory untouched>}" >&3
  local _cfbv_now _cfbv_next
  _cfbv_now="${CFBUNDLE_VERSION:-0}"
  if [[ "$_cfbv_now" =~ ^[0-9]+$ ]]; then
    _cfbv_next=$((_cfbv_now + 1))
  else
    _cfbv_next="<auto-bump skipped: not an integer>"
  fi
  echo "CFBUNDLE_VERSION:  $_cfbv_now (in .env; next auto-bump ships $_cfbv_next; --set-cfbundle-version overrides; USE_UE_PACKAGE_VERSION_COUNTER=1 disables Path B)" >&3
  echo "MAC_INFO_TEMPLATE_PLIST: $REPO_ROOT/Build/Mac/Resources/Info.Template.plist" >&3
  if [[ -n "${UPROJECT_NAME:-}" ]]; then
    echo "MAC_PACKAGE_VERSION_COUNTER: $REPO_ROOT/Build/Mac/${UPROJECT_NAME%.uproject}.PackageVersionCounter" >&3
  fi
  if [[ "$VERSION_MODE" == "MANUAL" || "$VERSION_MODE" == "HYBRID" ]]; then
    echo "VERSION_STRING:    $VERSION_STRING" >&3
  fi
  if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
    echo "WORKSPACE:         ${WORKSPACE:-<unset>}" >&3
    echo "SCHEME:            ${SCHEME:-<unset>}" >&3
    echo "XCODE_CONFIG:      ${XCODE_CONFIG:-<unset>}" >&3
  fi
  echo "NOTARIZE_ENABLED:  ${NOTARIZE_ENABLED:-<unset>}" >&3
  if [[ "$USE_XCODE_EXPORT" == "1" && "$MAC_DISTRIBUTION" == "developer-id" ]]; then
    echo "EXPORT_PLIST:      ${EXPORT_PLIST:-<unset>}" >&3
  fi
}

# Tracks the Content/<dir>/version.txt written before UAT; reset to "dev" on EXIT.
_CONTENT_VERSION_FILE_TO_RESTORE=""
# Set to 1 when --bump-* fires; causes VERSION_STRING to be persisted to .env on success.
_VERSION_BUMPED=""

# Reset Content/<dir>/version.txt to "dev" so the editor stays clean.
# Registered as an EXIT trap — safe to call multiple times.
restore_content_version_file() {
  [[ -z "${_CONTENT_VERSION_FILE_TO_RESTORE:-}" ]] && return 0
  local _f="$_CONTENT_VERSION_FILE_TO_RESTORE"
  _CONTENT_VERSION_FILE_TO_RESTORE=""
  if printf '%s' "dev" > "$_f"; then
    info "Reset $_f → 'dev'"
  else
    warn "Failed to reset $_f to 'dev' — restore manually"
  fi
}

# Resolve the version string for the current run.
_resolve_version_string() {
  local _ts _hash
  case "$VERSION_MODE" in
    MANUAL)
      echo "$VERSION_STRING"
      ;;
    DATETIME)
      _ts="$(date +%Y%m%d-%H%M%S)"
      _hash=""
      if /usr/bin/git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
        _hash="$(/usr/bin/git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
      fi
      if [[ -n "$_hash" ]]; then
        echo "${_ts}-${_hash}"
      else
        echo "$_ts"
      fi
      ;;
    HYBRID)
      # Manual base version + git short hash: e.g. "1.2.3-a1b2c3d"
      _hash=""
      if /usr/bin/git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
        _hash="$(/usr/bin/git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
      fi
      if [[ -n "$_hash" ]]; then
        echo "${VERSION_STRING}-${_hash}"
      else
        echo "$VERSION_STRING"
      fi
      ;;
    *)
      die "Unknown VERSION_MODE: $VERSION_MODE"
      ;;
  esac
}

# Stamp Content/<VERSION_CONTENT_DIR>/version.txt with the build version before
# UAT runs, so UAT bundles it automatically.  The EXIT trap resets it to "dev".
write_version_to_content() {
  [[ "$VERSION_MODE" == "NONE" ]] && return 0
  local _dest="$REPO_ROOT/Content/$VERSION_CONTENT_DIR/version.txt"
  local _version_string
  _version_string="$(_resolve_version_string)"
  /bin/mkdir -p "$(/usr/bin/dirname "$_dest")"
  printf '%s' "$_version_string" > "$_dest"
  /bin/chmod 644 "$_dest"
  _CONTENT_VERSION_FILE_TO_RESTORE="$_dest"
  good "Stamped $_dest → '$_version_string' (will reset to 'dev' on exit)"
}

# Add "+DirectoriesToAlwaysStageAsNonUFS=(Path="<dir>")" under
# [/Script/UnrealEd.ProjectPackagingSettings] in DefaultGame.ini if absent.
# This tells UAT to bundle the version directory into every build.
# Idempotent: does nothing if the entry is already present.
ensure_game_ini_staging_entry() {
  [[ "$VERSION_MODE" == "NONE" ]] && return 0
  local ini_file="$REPO_ROOT/Config/DefaultGame.ini"
  local section="[/Script/UnrealEd.ProjectPackagingSettings]"
  local entry="+DirectoriesToAlwaysStageAsNonUFS=(Path=\"$VERSION_CONTENT_DIR\")"
  local _line tmp_ini

  if [[ -f "$ini_file" ]] && /usr/bin/grep -qF "$entry" "$ini_file"; then
    info "DefaultGame.ini already contains staging entry for $VERSION_CONTENT_DIR"
    return 0
  fi

  if [[ -f "$ini_file" ]] && /usr/bin/grep -qF "$section" "$ini_file"; then
    # Section exists — insert entry immediately after the header line.
    tmp_ini="$(/usr/bin/mktemp "${TMPDIR:-/tmp}DefaultGame_ini_XXXXXX")"
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      printf '%s\n' "$_line"
      if [[ "$_line" == "$section" ]]; then
        printf '%s\n' "$entry"
      fi
    done < "$ini_file" > "$tmp_ini"
    /bin/mv "$tmp_ini" "$ini_file"
  else
    # Section absent (or file absent) — append section and entry.
    /bin/mkdir -p "$(/usr/bin/dirname "$ini_file")"
    printf '\n%s\n%s\n' "$section" "$entry" >> "$ini_file"
  fi
  good "Added staging entry to DefaultGame.ini: $entry"
}

# Persist the bumped VERSION_STRING back to .env on successful builds.
# If VERSION_STRING= is already in .env it is updated in-place; otherwise it is appended.
# Only runs when --bump-* was used this invocation.
write_bumped_version_to_env() {
  [[ -z "${_VERSION_BUMPED:-}" ]] && return 0
  _write_env_var "VERSION_STRING" "$VERSION_STRING"
}

# --- Canonical UE override helpers --------------------------------------------
#
# Earlier versions of this script post-processed the UE-generated xcconfig at
# Intermediate/ProjectFiles/XcconfigsMac/<LONG_NAME>.xcconfig to inject Info.plist
# values. That fought with GenerateProjectFiles every regen and put canonical
# project state in an Intermediate/ file. The helpers below route each value
# through its sanctioned UE override location instead, so values are visible to
# the user in committed config and survive every regen:
#
#   MARKETING_VERSION (CFBundleShortVersionString)
#     → Config/DefaultEngine.ini
#       [/Script/MacRuntimeSettings.MacRuntimeSettings]
#       VersionInfo=
#     Read by XcodeProject.cs::WriteXcconfigFile (line 1997 in UE 5.7).
#
#   LSApplicationCategoryType
#     → Config/DefaultEngine.ini
#       [/Script/MacTargetPlatform.XcodeProjectSettings]
#       AppCategory=
#     Read at XcodeProject.cs:1982. BaseEngine.ini already defaults this to
#     "public.app-category.games" — only override if you want a different value.
#
#   LSSupportsGameMode + GCSupportsGameMode
#     → Build/Mac/Resources/Info.Template.plist
#     UE's BaseEngine.ini sets TemplateMacPlist to this path; UE merges its
#     contents into the final Info.plist. The engine's stock template is
#     minimal and contains no GameMode keys — we add them here.
#
#   CFBundleVersion (CURRENT_PROJECT_VERSION)
#     → Build/Mac/<Project>.PackageVersionCounter
#     UE's UpdateVersionAfterBuild.sh reads this counter, increments the minor,
#     and writes Intermediate/Build/Versions.xcconfig with UE_MAC_BUILD_VERSION,
#     which the generated xcconfig references via $(UE_MAC_BUILD_VERSION). We
#     defensively seed the counter file at "0.0" so the first build produces
#     CFBundleVersion=0.0.1.

set_engine_ini_value() {
  # Idempotent setter for a key=value pair under a section in DefaultEngine.ini.
  # No-op when the value is already correct. Inserts after the section header
  # if the section exists but the key doesn't. Appends section + key if absent.
  local section="$1" key="$2" value="$3"
  local ini_file="$REPO_ROOT/Config/DefaultEngine.ini"
  local desired="${key}=${value}"
  local current_value
  local _line tmp_ini

  /bin/mkdir -p "$(/usr/bin/dirname "$ini_file")"
  [[ -f "$ini_file" ]] || : > "$ini_file"

  current_value="$(/usr/bin/awk -v section="$section" -v key="$key" '
    $0 == section { in_sect = 1; next }
    /^\[/ { in_sect = 0; next }
    in_sect && $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$ini_file")"

  if [[ "$current_value" == "$value" ]]; then
    info "DefaultEngine.ini already canonical: [$section] $desired"
    return 0
  fi

  if /usr/bin/grep -qF "$section" "$ini_file"; then
    if [[ -n "$current_value" ]]; then
      tmp_ini="$(/usr/bin/mktemp "${TMPDIR:-/tmp}DefaultEngine_ini_XXXXXX")"
      /usr/bin/awk -v section="$section" -v key="$key" -v new="$desired" '
        BEGIN { in_sect = 0 }
        $0 == section { in_sect = 1; print; next }
        /^\[/ { in_sect = 0; print; next }
        in_sect && $0 ~ "^[[:space:]]*"key"[[:space:]]*=" { print new; next }
        { print }
      ' "$ini_file" > "$tmp_ini"
      /bin/mv "$tmp_ini" "$ini_file"
      good "Updated $ini_file → [$section] $desired"
    else
      tmp_ini="$(/usr/bin/mktemp "${TMPDIR:-/tmp}DefaultEngine_ini_XXXXXX")"
      while IFS= read -r _line || [[ -n "$_line" ]]; do
        printf '%s\n' "$_line"
        if [[ "$_line" == "$section" ]]; then
          printf '%s\n' "$desired"
        fi
      done < "$ini_file" > "$tmp_ini"
      /bin/mv "$tmp_ini" "$ini_file"
      good "Inserted into $ini_file under $section: $desired"
    fi
  else
    printf '\n%s\n%s\n' "$section" "$desired" >> "$ini_file"
    good "Appended to $ini_file: $section $desired"
  fi
}

ensure_marketing_version_in_engine_ini() {
  # Write MARKETING_VERSION (CFBundleShortVersionString) to its canonical
  # locations. UE has separate ini sections for Mac and iOS runtime settings
  # — both keys are read by XcodeProject.cs::WriteXcconfigFile (lines 1997
  # and 2011 respectively) and stamped into the generated xcconfig.
  #
  # By default, MARKETING_VERSION is shared across platforms — we write the
  # same value to both sections so Mac and iOS ship with the same display
  # version. If IOS_MARKETING_VERSION is set, it overrides the iOS-side
  # value only (rare, but useful when platforms ship on different cadences).
  [[ -n "${MARKETING_VERSION:-}" || -n "${IOS_MARKETING_VERSION:-}" ]] || return 0

  if [[ -n "${MARKETING_VERSION:-}" ]]; then
    set_engine_ini_value \
      "[/Script/MacRuntimeSettings.MacRuntimeSettings]" \
      "VersionInfo" \
      "$MARKETING_VERSION"
  fi

  # iOS section: explicit IOS_MARKETING_VERSION wins; otherwise inherit
  # MARKETING_VERSION. We only write when ENABLE_IOS=1 (or when the user
  # explicitly set IOS_MARKETING_VERSION) to avoid touching the iOS section
  # for Mac-only projects.
  local ios_value="${IOS_MARKETING_VERSION:-${MARKETING_VERSION:-}}"
  if [[ -n "$ios_value" ]] && [[ "${ENABLE_IOS:-0}" == "1" || -n "${IOS_MARKETING_VERSION:-}" ]]; then
    set_engine_ini_value \
      "[/Script/IOSRuntimeSettings.IOSRuntimeSettings]" \
      "VersionInfo" \
      "$ios_value"
  fi
}

ensure_app_category_in_engine_ini() {
  # Write LSApplicationCategoryType to its canonical location when the user
  # has supplied one. UE's BaseEngine.ini default is "public.app-category.games";
  # only override when needed.
  [[ -n "${APP_CATEGORY:-}" ]] || return 0
  set_engine_ini_value \
    "[/Script/MacTargetPlatform.XcodeProjectSettings]" \
    "AppCategory" \
    "$APP_CATEGORY"
}

_seed_entitlements_file_if_missing() {
  # Create a minimal entitlements plist at $1 if it doesn't exist. The body
  # is an empty <dict/> so subsequent _set_entitlement_bool / PlistBuddy
  # Add calls have a valid container to write into. Idempotent.
  local ent_path="$1"
  [[ -f "$ent_path" ]] && return 0

  /bin/mkdir -p "$(/usr/bin/dirname "$ent_path")"
  cat > "$ent_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
  /bin/chmod 644 "$ent_path"
  good "Seeded empty entitlements file $ent_path (commit it — populated by subsequent helpers, passed as CODE_SIGN_ENTITLEMENTS to xcodebuild)"
}

_set_entitlement_bool() {
  # Idempotent bool setter for a top-level entitlements key. Skips when the
  # current value already matches. Adds the key if absent, Sets if present
  # with a different value. The plist must already exist — call
  # _seed_entitlements_file_if_missing first.
  #   $1 = entitlements file path
  #   $2 = key (e.g. com.apple.security.app-sandbox)
  #   $3 = "true" or "false"
  local ent_path="$1" key="$2" value="$3"
  local current
  current="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ent_path" 2>/dev/null || true)"
  if [[ "$current" == "$value" ]]; then
    info "Entitlements file $ent_path already has $key=$value"
    return 0
  fi
  if [[ -n "$current" ]]; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$ent_path"
  else
    /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$ent_path"
  fi
  good "Updated $ent_path → $key=$value"
}

_delete_entitlement_key_if_present() {
  # Remove a key from an entitlements file if present. Idempotent: no-op
  # when the file doesn't exist or the key isn't there.
  local ent_path="$1" key="$2"
  [[ -f "$ent_path" ]] || return 0
  local current
  current="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ent_path" 2>/dev/null || true)"
  if [[ -n "$current" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :$key" "$ent_path"
    good "Removed $key from $ent_path"
  else
    info "$key not present in $ent_path — nothing to remove"
  fi
}

_ensure_game_center_entitlement_for_platform() {
  # Per-platform worker for ensure_game_center_entitlements. $1 is the
  # entitlements file path; $2 is "add" or "remove". Idempotent. Composes
  # on top of an existing entitlements file via _set_entitlement_bool —
  # other keys (sandbox, network.client, etc.) are untouched.
  local ent_path="$1" action="$2"

  if [[ "$action" == "add" ]]; then
    _seed_entitlements_file_if_missing "$ent_path"
    _set_entitlement_bool "$ent_path" "com.apple.developer.game-center" "true"
  else
    _delete_entitlement_key_if_present "$ent_path" "com.apple.developer.game-center"
  fi
}

mac_app_store_entitlements_path() {
  # Single source of truth for the Mac App Store entitlements file path.
  # Used by ensure_mac_app_store_entitlements (the seeder) and the MAS
  # archive command (CODE_SIGN_ENTITLEMENTS). Lives in
  # Build/Mac/Resources/<Project>.entitlements — UE's canonical location.
  printf '%s' "$REPO_ROOT/Build/Mac/Resources/${UPROJECT_NAME%.uproject}.entitlements"
}

ensure_mac_app_store_entitlements() {
  # Mac App Store baseline: com.apple.security.app-sandbox=true is REQUIRED.
  # ASC rejects any MAS upload without it. UE ships
  # Build/Mac/Resources/Sandbox.NoNet.entitlements as its stock template for
  # Shipping (referenced via ShippingSpecificMacEntitlements in BaseEngine.ini)
  # — but as soon as we pass CODE_SIGN_ENTITLEMENTS=<path> to xcodebuild
  # archive (which we always do under MAC_DISTRIBUTION=app-store for Game
  # Center + future extensions), that override shadows UE's path. So this
  # helper owns the canonical MAS entitlements file at
  # Build/Mac/Resources/<Project>.entitlements and seeds the sandbox key
  # before any other entitlement helpers (Game Center, etc.) run.
  #
  # Idempotent. Composes cleanly with ensure_game_center_entitlements, which
  # only touches the game-center / network.client keys via PlistBuddy.
  [[ "${MAC_DISTRIBUTION:-developer-id}" == "app-store" ]] || return 0

  local ent_path
  ent_path="$(mac_app_store_entitlements_path)"
  _seed_entitlements_file_if_missing "$ent_path"
  _set_entitlement_bool "$ent_path" "com.apple.security.app-sandbox" "true"
}

ensure_game_center_entitlements() {
  # Manage com.apple.developer.game-center for the eligible distribution
  # channels. Unset = no opinion; 1 = add the entitlement; 0 = remove it.
  #
  # Eligible channels:
  #   - iOS (IOS_DISTRIBUTION=app-store): seeds Build/IOS/Resources/<Project>.entitlements
  #     and writes bEnableGameCenterSupport under [/Script/IOSRuntimeSettings.IOSRuntimeSettings].
  #   - Mac App Store (MAC_DISTRIBUTION=app-store): updates
  #     Build/Mac/Resources/<Project>.entitlements (already seeded with
  #     sandbox by ensure_mac_app_store_entitlements), adds
  #     com.apple.developer.game-center=true AND com.apple.security.network.client=true
  #     (Game Center cannot reach Apple's servers without outbound network),
  #     and writes bEnableGameCenterSupport under
  #     [/Script/MacRuntimeSettings.MacRuntimeSettings].
  #
  # Not eligible: MAC_DISTRIBUTION=developer-id — AMFI rejects
  # com.apple.developer.game-center on Developer-ID-signed Mac apps at exec
  # regardless of notarization, because Apple does not encode the entitlement
  # into Developer ID provisioning profile binaries. validate_distribution_compatibility
  # already fails fast on that combination, so we don't need to re-check here.
  #
  # In both eligible cases we pass CODE_SIGN_ENTITLEMENTS=<path> directly to
  # xcodebuild archive — UBT's `bEnableGameCenterSupport=True` only writes to
  # Intermediate/<Platform>, which xcodebuild ignores under automatic signing.
  [[ -n "${ENABLE_GAME_CENTER:-}" ]] || return 0

  local project_name="${UPROJECT_NAME%.uproject}"
  local action="remove"
  [[ "$ENABLE_GAME_CENTER" == "1" ]] && action="add"

  local touched=0

  if [[ "${IOS_DISTRIBUTION:-off}" == "app-store" ]]; then
    local ios_ent="$REPO_ROOT/Build/IOS/Resources/${project_name}.entitlements"
    _ensure_game_center_entitlement_for_platform "$ios_ent" "$action"
    set_engine_ini_value \
      "[/Script/IOSRuntimeSettings.IOSRuntimeSettings]" \
      "bEnableGameCenterSupport" \
      "$([[ "$action" == "add" ]] && echo "True" || echo "False")"
    touched=1
  fi

  # MAC_DISTRIBUTION=app-store: full add/remove management.
  # MAC_DISTRIBUTION=developer-id + remove: also clean up. UE points
  # ShippingSpecificMacEntitlements at the same Build/Mac/Resources/<Project>.entitlements
  # we manage for MAS, so a leftover com.apple.developer.game-center=true (from a prior
  # MAS run) causes exportArchive to fail with "No profiles for '<bundle id>' were found" —
  # Developer ID provisioning profiles cannot carry the game-center entitlement.
  # (Add under developer-id is blocked earlier by validate_distribution_compatibility.)
  if [[ "${MAC_DISTRIBUTION:-developer-id}" == "app-store" \
        || ( "${MAC_DISTRIBUTION:-developer-id}" == "developer-id" && "$action" == "remove" ) ]]; then
    local mac_ent
    mac_ent="$(mac_app_store_entitlements_path)"
    _ensure_game_center_entitlement_for_platform "$mac_ent" "$action"
    if [[ "$action" == "add" ]]; then
      # Game Center talks to Apple's servers — without
      # com.apple.security.network.client the entitlement is technically
      # present but the SDK's network calls fail silently from inside the
      # sandbox. Auto-add. (User can remove from the file if they truly
      # don't want it; our idempotent setter only fires when value differs.)
      info "Enabling com.apple.security.network.client (required for Game Center to reach Apple servers from the sandbox)"
      _set_entitlement_bool "$mac_ent" "com.apple.security.network.client" "true"
    fi
    set_engine_ini_value \
      "[/Script/MacRuntimeSettings.MacRuntimeSettings]" \
      "bEnableGameCenterSupport" \
      "$([[ "$action" == "add" ]] && echo "True" || echo "False")"
    touched=1
  fi

  if [[ "$touched" -eq 0 ]]; then
    warn "ENABLE_GAME_CENTER=$ENABLE_GAME_CENTER but no eligible channel — set MAC_DISTRIBUTION=app-store and/or IOS_DISTRIBUTION=app-store (Game Center is a Mac App Store / iOS feature; AMFI rejects it on Developer-ID Mac builds). Skipping."
  fi
}

seed_mac_info_template_plist() {
  # Defensively place a Mac Info.Template.plist at the canonical project path.
  # When the file is missing, copy the engine's stock template; when GameMode
  # keys are requested via --game-mode / --no-game-mode, set them via PlistBuddy
  # (idempotent: skips when value already matches).
  #
  # BaseEngine.ini ships TemplateMacPlist=(FilePath="/Game/Build/Mac/Resources/Info.Template.plist"),
  # so any plist landing here is auto-discovered by UE — no ini override required.
  [[ "${SEED_MAC_INFO_TEMPLATE_PLIST:-1}" == "1" ]] || { info "Skipping Info.Template.plist seed (SEED_MAC_INFO_TEMPLATE_PLIST=0)"; return 0; }

  local src dst_dir dst
  src="$UE_ROOT/Engine/Build/Mac/Resources/Info.Template.plist"
  dst_dir="$REPO_ROOT/Build/Mac/Resources"
  dst="$dst_dir/Info.Template.plist"

  if [[ ! -f "$dst" ]]; then
    if [[ ! -f "$src" ]]; then
      warn "Engine Info.Template.plist not found at $src — skipping plist seed"
      return 0
    fi
    /bin/mkdir -p "$dst_dir"
    /bin/cp "$src" "$dst"
    /bin/chmod 644 "$dst"
    good "Seeded $dst from engine stock (commit it; UE merges this into the final Info.plist)"
  else
    info "Mac Info.Template.plist already present: $dst"
  fi

  # GameMode keys — only touch the plist when the user supplied an explicit
  # preference. Otherwise the user's plist is sovereign.
  if [[ -n "${ENABLE_GAME_MODE:-}" ]]; then
    local _game_mode_val="false"
    [[ "$ENABLE_GAME_MODE" == "1" ]] && _game_mode_val="true"
    _set_plist_bool "$dst" "LSSupportsGameMode" "$_game_mode_val"
    _set_plist_bool "$dst" "GCSupportsGameMode" "$_game_mode_val"
  fi
}

_set_plist_bool() {
  # Idempotent bool setter for a top-level plist key. Skips writing when the
  # current value already matches.
  local plist="$1" key="$2" value="$3"
  local current
  current="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  if [[ "$current" == "$value" ]]; then
    info "Plist $plist already has $key=$value"
    return 0
  fi
  if [[ -n "$current" ]]; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$plist"
  fi
  good "Updated $plist → $key=$value"
}

_resolve_cfbundle_version_for_build() {
  # Decide what value CFBundleVersion should be for this build, based on:
  #   - USE_UE_PACKAGE_VERSION_COUNTER=1 → Path A; clear CFBUNDLE_VERSION so
  #     xcodebuild's build-setting override is empty and UE's xcconfig
  #     "CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION)" wins. No persist.
  #   - --set-cfbundle-version N (CLI_SET_CFBUNDLE_VERSION=1) → use N as-is,
  #     persist to .env on success ("new baseline" semantics).
  #   - Default Path B → auto pre-increment the integer in CFBUNDLE_VERSION
  #     (treating empty/missing as 0), persist on success. With .env at 0,
  #     the first build ships CFBundleVersion=1.
  # The resolved value is passed to xcodebuild as a CURRENT_PROJECT_VERSION=...
  # build-setting override, which Apple-documented behavior says takes
  # precedence over xcconfig. Xcode bakes the value into both the .app's
  # Info.plist and the .xcarchive's metadata at archive time.
  # Sets CFBUNDLE_VERSION (the ship value) and _CFBV_PERSIST (1 if we should
  # write the value back to .env on successful build).
  _CFBV_PERSIST=0

  if [[ "${USE_UE_PACKAGE_VERSION_COUNTER:-0}" == "1" ]]; then
    info "Path A enabled (USE_UE_PACKAGE_VERSION_COUNTER=1) — CFBundleVersion comes from UE's PackageVersionCounter; skipping build-setting override"
    CFBUNDLE_VERSION=""
    return 0
  fi

  if [[ "${CLI_SET_CFBUNDLE_VERSION:-0}" == "1" ]]; then
    [[ -n "$CFBUNDLE_VERSION" ]] || die "--set-cfbundle-version requires a value"
    _CFBV_PERSIST=1
    info "CFBundleVersion baseline set explicitly via --set-cfbundle-version: $CFBUNDLE_VERSION (will persist to .env on success)"
    return 0
  fi

  # Default Path B: auto pre-increment the integer in CFBUNDLE_VERSION.
  local _current="${CFBUNDLE_VERSION:-0}"
  [[ -z "$_current" ]] && _current=0
  if [[ "$_current" =~ ^[0-9]+$ ]]; then
    CFBUNDLE_VERSION=$((_current + 1))
    _CFBV_PERSIST=1
    info "CFBundleVersion auto-bumped: $_current → $CFBUNDLE_VERSION (will persist to .env on success)"
  else
    warn "CFBUNDLE_VERSION='$_current' is not a pure integer; auto-bump skipped. Pass --set-cfbundle-version N to reset to a clean integer baseline."
    _CFBV_PERSIST=0
  fi
}

_write_env_var() {
  # Idempotent in-place writer for a NAME="value" pair in .env. Updates the
  # line if NAME= exists, otherwise appends. Creates .env if missing.
  local name="$1" value="$2"
  local new_line="${name}=\"${value}\""
  local tmp _line

  if [[ ! -f "$ENV_FILE" ]]; then
    printf '%s\n' "$new_line" > "$ENV_FILE"
    good "Created $ENV_FILE with $new_line"
    return 0
  fi

  if /usr/bin/grep -q "^${name}=" "$ENV_FILE"; then
    tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}env_update_XXXXXX")"
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      if [[ "$_line" == "${name}="* ]]; then
        printf '%s\n' "$new_line"
      else
        printf '%s\n' "$_line"
      fi
    done < "$ENV_FILE" > "$tmp"
    /bin/mv "$tmp" "$ENV_FILE"
  else
    printf '\n%s\n' "$new_line" >> "$ENV_FILE"
  fi
  good "Persisted to $ENV_FILE: $new_line"
}

write_cfbundle_version_to_env() {
  # Persist the CFBundleVersion that just shipped back to .env so the next
  # auto-bump build picks up where this one left off. Only runs on a
  # successful build path (called from end-of-script alongside
  # write_bumped_version_to_env). No-op when:
  #   - Path A is in use (CFBUNDLE_VERSION was cleared by the resolver)
  #   - CFBUNDLE_VERSION is non-integer-valued and auto-bump was skipped
  [[ "${_CFBV_PERSIST:-0}" == "1" ]] || return 0
  [[ -n "${CFBUNDLE_VERSION:-}" ]] || return 0
  _write_env_var "CFBUNDLE_VERSION" "$CFBUNDLE_VERSION"
}

seed_mac_update_version_after_build_script() {
  # Drop a project-level UpdateVersionAfterBuild.sh that strips the engine's
  # Perforce changelist prefix from CFBundleVersion. UE's AppleToolChain.cs at
  # lines 394-397 explicitly checks the project for this script and falls back
  # to the engine's copy only if absent — this is the sanctioned override path.
  #
  # Why we do it: the engine script writes
  #     UE_MAC_BUILD_VERSION = <CL>.<MAC_VERSION>
  # where <CL> is the Changelist field from Engine/Build/Build.version. For an
  # Epic Games Launcher install of 5.7.4 that is 51494982, so projects ship
  # CFBundleVersion=51494982.0.2 — almost never what you want. Our override
  # writes:
  #     UE_MAC_BUILD_VERSION = <MAC_VERSION>
  # so CFBundleVersion ships as the PackageVersionCounter contents (e.g. 0.2).
  #
  # The override is otherwise byte-identical to the engine's script: same
  # PackageVersionCounter read/increment logic, same Versions.xcconfig output
  # path, same handling of the Mac/IOS/TVOS/VisionOS counters.
  #
  # Idempotent: skips if the destination already exists. Gated on
  # USE_UE_PACKAGE_VERSION_COUNTER (default 0, opt-in for advanced users).
  [[ "${USE_UE_PACKAGE_VERSION_COUNTER:-0}" == "1" ]] || return 0

  local dst_dir dst
  dst_dir="$REPO_ROOT/Build/BatchFiles/Mac"
  dst="$dst_dir/UpdateVersionAfterBuild.sh"

  if [[ -f "$dst" ]]; then
    info "Project UpdateVersionAfterBuild.sh already present: $dst"
    return 0
  fi

  /bin/mkdir -p "$dst_dir"
  /bin/cat > "$dst" <<'OVERRIDE'
#!/bin/bash
# Project-level override of UE's UpdateVersionAfterBuild.sh.
#
# UE's AppleToolChain.cs::UpdateVersionFile checks for this file at
#   <project>/Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh
# and falls back to the engine's copy only if absent.
# Reference: AppleToolChain.cs:394-397.
#
# Differs from the engine version only in that CFBundleVersion is NOT prefixed
# with the engine's Build.version Changelist (e.g. 51494982 in 5.7.4). That CL
# leaks into shipping builds as a giant build number, which most projects
# don't want. The PackageVersionCounter contents (e.g. "0.2") become
# UE_MAC_BUILD_VERSION verbatim, so CFBundleVersion=0.2 in the shipped app.
#
# Args (UE-provided):
#   $1 = product directory (project root for projects, engine for engine builds)
#   $2 = platform we are incrementing
#   $3 = engine changelist (intentionally ignored by this override)
#
# Maintained by ship.sh; regenerate by deleting this file and re-running ship.sh.

PRODUCT_NAME=$(basename "$1")
VERSION_FILE_DIR="$1/Build/$2"
VERSION_FILE="$VERSION_FILE_DIR/$PRODUCT_NAME.PackageVersionCounter"

VERSION="0.1"
if [ -f "$VERSION_FILE" ]; then
	VERSION=$(cat "$VERSION_FILE")
fi

IFS="." read -ra VERSION_ARRAY <<< "$VERSION"

mkdir -p "${VERSION_FILE_DIR}"
echo "${VERSION_ARRAY[0]}.$((VERSION_ARRAY[1]+1))" > "$VERSION_FILE"


MAC_VERSION="0.1"
VERSION_FILE="$1/Build/Mac/$PRODUCT_NAME.PackageVersionCounter"
if [ -f "$VERSION_FILE" ]; then
	MAC_VERSION=$(cat "$VERSION_FILE")
fi

IOS_VERSION="0.1"
VERSION_FILE="$1/Build/IOS/$PRODUCT_NAME.PackageVersionCounter"
if [ -f "$VERSION_FILE" ]; then
	IOS_VERSION=$(cat "$VERSION_FILE")
fi

TVOS_VERSION="0.1"
VERSION_FILE="$1/Build/TVOS/$PRODUCT_NAME.PackageVersionCounter"
if [ -f "$VERSION_FILE" ]; then
	TVOS_VERSION=$(cat "$VERSION_FILE")
fi

VISIONOS_VERSION="0.1"
VERSION_FILE="$1/Build/VisionOS/$PRODUCT_NAME.PackageVersionCounter"
if [ -f "$VERSION_FILE" ]; then
	VISIONOS_VERSION=$(cat "$VERSION_FILE")
fi

XCCONFIG_FILE="$1/Intermediate/Build/Versions.xcconfig"

mkdir -p "$1/Intermediate/Build"
echo "UE_MAC_BUILD_VERSION = $MAC_VERSION" > "$XCCONFIG_FILE"
echo "UE_IOS_BUILD_VERSION = $IOS_VERSION" >> "$XCCONFIG_FILE"
echo "UE_TVOS_BUILD_VERSION = $TVOS_VERSION" >> "$XCCONFIG_FILE"
echo "UE_VISIONOS_BUILD_VERSION = $VISIONOS_VERSION" >> "$XCCONFIG_FILE"
OVERRIDE
  /bin/chmod 755 "$dst"
  good "Seeded $dst (drops CL prefix from CFBundleVersion; commit it)"
}

seed_mac_package_version_counter() {
  # Defensively seed Build/Mac/<Project>.PackageVersionCounter with "0.0" when
  # missing. UE's UpdateVersionAfterBuild.sh reads this file at xcodebuild time,
  # increments the minor (0.0 → 0.1 → 0.2 → ...), and writes the value into
  # Intermediate/Build/Versions.xcconfig as UE_MAC_BUILD_VERSION. The generated
  # xcconfig references it via CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION),
  # so CFBundleVersion auto-increments per build with no further work.
  #
  # If you want a specific starting value, edit the counter file directly; the
  # script never overwrites an existing one.
  [[ "${USE_UE_PACKAGE_VERSION_COUNTER:-0}" == "1" ]] || return 0

  local base counter_dir counter_file
  base="${UPROJECT_NAME%.uproject}"
  counter_dir="$REPO_ROOT/Build/Mac"
  counter_file="$counter_dir/${base}.PackageVersionCounter"

  if [[ -f "$counter_file" ]]; then
    info "PackageVersionCounter already present: $counter_file"
    return 0
  fi
  /bin/mkdir -p "$counter_dir"
  printf '%s' "0.0" > "$counter_file"
  /bin/chmod 644 "$counter_file"
  good "Seeded $counter_file → 0.0 (UE auto-increments to 0.1 on first build)"
}

autodetect_workspace_if_needed() {
  # If the workspace is placeholder/empty AND Xcode export is enabled, try to discover it.
  if [[ "$USE_XCODE_EXPORT" == "1" ]] && is_placeholder "$XCODE_WORKSPACE"; then
    info "XCODE_WORKSPACE not set — attempting auto-detect"
    local found=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && found+=("$line")
    done < <(/usr/bin/find "$REPO_ROOT" -maxdepth 2 -type d -name '*.xcworkspace' 2>/dev/null)
    if [[ "${#found[@]}" -eq 1 ]]; then
      XCODE_WORKSPACE="$(/usr/bin/basename "${found[0]}")"
      WORKSPACE="${found[0]}"
      info "Auto-detected workspace: $WORKSPACE"
    elif [[ "${#found[@]}" -eq 0 ]]; then
      if [[ "${REGEN_PROJECT_FILES:-1}" == "1" ]]; then
        die "GenerateProjectFiles ran but no .xcworkspace was found under REPO_ROOT: $REPO_ROOT. Check that UPROJECT_PATH points to a valid .uproject."
      else
        die "No .xcworkspace found under REPO_ROOT: $REPO_ROOT. Set XCODE_WORKSPACE explicitly, or remove --no-regen-project-files / REGEN_PROJECT_FILES=0 to let the script generate it."
      fi
    fi

    # At this point we have 2+ candidates.
    # Common Unreal output: both "<Project> (iOS).xcworkspace" and "<Project> (Mac).xcworkspace".
    # Prefer the macOS workspace automatically when present.
    local mac_found=()
    local p
    for p in "${found[@]}"; do
      if [[ "$p" == *" (Mac).xcworkspace" ]]; then
        mac_found+=("$p")
      fi
    done

    if [[ "${#mac_found[@]}" -eq 1 ]]; then
      XCODE_WORKSPACE="$(/usr/bin/basename "${mac_found[0]}")"
      WORKSPACE="${mac_found[0]}"
      info "Auto-selected macOS workspace: $WORKSPACE"

    elif [[ "${#mac_found[@]}" -gt 1 ]]; then
      # If there are multiple macOS workspaces, prefer the one that matches the project naming convention.
      local base expected matches=()
      base="${UPROJECT_NAME%.uproject}"
      expected="$REPO_ROOT/${base} (Mac).xcworkspace"

      for p in "${mac_found[@]}"; do
        if [[ "$p" == "$expected" ]]; then
          matches+=("$p")
        fi
      done

      if [[ "${#matches[@]}" -eq 1 ]]; then
        XCODE_WORKSPACE="$(/usr/bin/basename "${matches[0]}")"
        WORKSPACE="${matches[0]}"
        info "Auto-selected macOS workspace (matched convention): $WORKSPACE"
      else
        echo "Found multiple macOS .xcworkspace candidates:" >&3
        local i=1
        for p in "${mac_found[@]}"; do
          echo "  [$i] $p" >&3
          i=$((i+1))
        done

        local chosen
        chosen="$(choose_from_list_interactively "Select macOS workspace" 1 "${mac_found[@]}")"
        if [[ -n "$chosen" ]]; then
          XCODE_WORKSPACE="$(/usr/bin/basename "$chosen")"
          WORKSPACE="$chosen"
          info "Selected macOS workspace: $WORKSPACE"
        else
          die "Multiple macOS workspaces found. Set XCODE_WORKSPACE explicitly (or run interactively to choose)."
        fi
      fi
    else
      # No macOS workspace found — show candidates and offer selection.
      echo "Found multiple .xcworkspace candidates (none look like '(Mac).xcworkspace'):" >&3
      local i=1
      for p in "${found[@]}"; do
        echo "  [$i] $p" >&3
        i=$((i+1))
      done

      local chosen
      chosen="$(choose_from_list_interactively "Select workspace" 1 "${found[@]}")"
      if [[ -n "$chosen" ]]; then
        XCODE_WORKSPACE="$(/usr/bin/basename "$chosen")"
        WORKSPACE="$chosen"
        info "Selected workspace: $WORKSPACE"
      else
        die "No '(Mac).xcworkspace' found. Generate Mac project files or set XCODE_WORKSPACE explicitly."
      fi
    fi
  fi
}

autodetect_scheme_if_needed() {
  # If scheme is placeholder/empty AND Xcode export is enabled, try to discover it from xcodebuild.
  if [[ "$USE_XCODE_EXPORT" == "1" ]] && is_placeholder "$XCODE_SCHEME"; then
    info "XCODE_SCHEME not set — attempting auto-detect"

    local list
    list=$(xcodebuild -list -workspace "$WORKSPACE" 2>/dev/null || true)
    if [[ -z "$list" ]]; then
      die "Could not list schemes from workspace. Open the workspace in Xcode and ensure a Shared scheme exists."
    fi

    local schemes=()
    local in_section=0

    while IFS= read -r line; do
      # Look for the "Schemes:" header (it may be indented in some Xcode versions).
      if [[ "$in_section" -eq 0 ]]; then
        if [[ "$line" =~ ^[[:space:]]*Schemes:[[:space:]]*$ ]]; then
          in_section=1
        fi
        continue
      fi

      # Once in the schemes section:
      # - collect indented, non-empty lines
      # - ignore blank lines
      # - stop when we hit a non-indented line
      if [[ -z "$line" ]]; then
        continue
      fi

      if [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
        # Trim leading whitespace
        local trimmed
        trimmed="${line#"${line%%[![:space:]]*}"}"
        schemes+=("$trimmed")
      else
        break
      fi
    done <<< "$list"

    if [[ "${#schemes[@]}" -eq 1 ]]; then
      XCODE_SCHEME="${schemes[0]}"
      SCHEME="$XCODE_SCHEME"
      info "Auto-detected scheme: $SCHEME"

    elif [[ "${#schemes[@]}" -eq 0 ]]; then
      die "No schemes found in workspace. Make sure the scheme exists and is marked Shared (Product → Scheme → Manage Schemes…)."

    else
      # Prefer an exact match to the detected project/app name.
      local base module preferred chosen=""
      base="${UPROJECT_NAME%.uproject}"
      module="$(read_uproject_module_name "$UPROJECT_PATH")"

      preferred=""
      if ! is_placeholder "$LONG_NAME"; then
        preferred="$LONG_NAME"
      elif [[ -n "$module" ]]; then
        preferred="$module"
      else
        preferred="$base"
      fi

      # Try to choose a single exact match in priority order.
      local candidates=()
      candidates+=("$preferred")
      [[ -n "$module" ]] && candidates+=("$module")
      candidates+=("$base")
      if ! is_placeholder "$SHORT_NAME"; then
        candidates+=("$SHORT_NAME")
      fi

      local c s
      for c in "${candidates[@]}"; do
        for s in "${schemes[@]}"; do
          if [[ "$s" == "$c" ]]; then
            chosen="$s"
            break 2
          fi
        done
      done

      if [[ -n "$chosen" ]]; then
        XCODE_SCHEME="$chosen"
        SCHEME="$XCODE_SCHEME"
        info "Auto-selected scheme by exact match: $SCHEME"

        echo "Schemes (auto-selected):" >&3
        for s in "${schemes[@]}"; do
          if [[ "$s" == "$chosen" ]]; then
            echo "  -> $s" >&3
          else
            echo "     $s" >&3
          fi
        done
      else
        echo "Available schemes:" >&3
        printf '  - %s\n' "${schemes[@]}" >&3
        die "Multiple schemes found and none matched the detected name. Set XCODE_SCHEME explicitly."
      fi
    fi
  fi
}

autodetect_ios_workspace_if_needed() {
  # Mirror autodetect_workspace_if_needed for the iOS workspace. UE generates
  # "<Project> (iOS).xcworkspace" alongside the Mac one in a single regen.
  [[ "${ENABLE_IOS:-0}" == "1" ]] || return 0
  is_placeholder "${IOS_WORKSPACE:-}" || return 0

  local base guess
  base="${UPROJECT_NAME%.uproject}"
  guess="$REPO_ROOT/${base} (iOS).xcworkspace"
  if [[ -d "$guess" ]]; then
    IOS_WORKSPACE="$guess"
    info "Auto-detected iOS workspace by convention: $IOS_WORKSPACE"
    return 0
  fi

  local found=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && found+=("$line")
  done < <(/usr/bin/find "$REPO_ROOT" -maxdepth 2 -type d -name '*iOS*.xcworkspace' 2>/dev/null)

  if [[ "${#found[@]}" -eq 1 ]]; then
    IOS_WORKSPACE="${found[0]}"
    info "Auto-detected iOS workspace: $IOS_WORKSPACE"
    return 0
  fi

  if [[ "${#found[@]}" -gt 1 ]]; then
    warn "Multiple iOS .xcworkspace candidates found. Set IOS_WORKSPACE explicitly."
  fi
}

autodetect_ios_scheme_if_needed() {
  [[ "${ENABLE_IOS:-0}" == "1" ]] || return 0
  is_placeholder "${IOS_SCHEME:-}" || return 0
  [[ -d "${IOS_WORKSPACE:-}" ]] || return 0

  # If the Mac scheme was resolved, iOS typically uses the same name.
  if ! is_placeholder "${XCODE_SCHEME:-}"; then
    IOS_SCHEME="$XCODE_SCHEME"
    info "iOS scheme inferred from Mac scheme: $IOS_SCHEME"
    return 0
  fi

  info "IOS_SCHEME not set — attempting auto-detect from iOS workspace"
  local list
  list="$(xcodebuild -list -workspace "$IOS_WORKSPACE" 2>/dev/null || true)"
  if [[ -z "$list" ]]; then
    warn "Could not list schemes from iOS workspace: $IOS_WORKSPACE"
    return 0
  fi

  local schemes=() in_section=0
  while IFS= read -r line; do
    if [[ "$in_section" -eq 0 ]]; then
      if [[ "$line" =~ ^[[:space:]]*Schemes:[[:space:]]*$ ]]; then
        in_section=1
      fi
      continue
    fi
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
      local trimmed
      trimmed="${line#"${line%%[![:space:]]*}"}"
      schemes+=("$trimmed")
    else
      break
    fi
  done <<< "$list"

  if [[ "${#schemes[@]}" -eq 1 ]]; then
    IOS_SCHEME="${schemes[0]}"
    info "Auto-detected iOS scheme: $IOS_SCHEME"
  elif [[ "${#schemes[@]}" -gt 1 ]]; then
    local base expected s
    base="${UPROJECT_NAME%.uproject}"
    expected="$base"
    for s in "${schemes[@]}"; do
      if [[ "$s" == "$expected" ]]; then
        IOS_SCHEME="$s"
        info "Auto-selected iOS scheme (name match): $IOS_SCHEME"
        return 0
      fi
    done
    warn "Multiple iOS schemes found, none matched project name. Set IOS_SCHEME explicitly."
  fi
}

autodetect_mas_export_plist_if_needed() {
  # Auto-detect MAS-ExportOptions.plist by conventional name in repo root.
  # MAS uses method=app-store-connect, same as iOS — so a content-based scan
  # would tie iOS and Mac App Store plists; require the conventional filename
  # ("MAS-ExportOptions.plist") to disambiguate.
  [[ "${MAC_DISTRIBUTION:-developer-id}" == "app-store" ]] || return 0
  is_placeholder "${MAS_EXPORT_PLIST:-}" || return 0

  local conventional="$REPO_ROOT/MAS-ExportOptions.plist"
  if [[ -f "$conventional" ]]; then
    MAS_EXPORT_PLIST="$conventional"
    info "Auto-detected MAS ExportOptions.plist (by name): $MAS_EXPORT_PLIST"
    return 0
  fi

  # No conventional plist on disk — offer to generate one interactively.
  # Falls through to a warn if the user is in a non-TTY context or declines.
  if maybe_generate_mas_export_plist_interactively; then
    return 0
  fi

  warn "No MAS-ExportOptions.plist found. Copy MAS-ExportOptions.plist.example to MAS-ExportOptions.plist and edit, or pass --mas-export-plist PATH."
}

maybe_generate_mas_export_plist_interactively() {
  # Offer to generate a minimal MAS-ExportOptions.plist suitable for Mac App
  # Store exports. Only runs in interactive terminals. Mirrors
  # maybe_generate_export_plist_interactively (Developer ID) but writes the
  # MAS template content. When DEVELOPMENT_TEAM is unset, writes the
  # YOUR_TEAM_ID placeholder + warns — the pre-flight teamID validator catches
  # a forgotten edit before the multi-hour build.
  if [[ ! -t 0 ]]; then
    return 1
  fi

  local out
  out="$REPO_ROOT/MAS-ExportOptions.plist"

  echo "No MAS-ExportOptions.plist was detected." >&3
  echo "I can generate a minimal one for Mac App Store exports." >&3
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "Team ID: $DEVELOPMENT_TEAM" >&3
  else
    echo "Team ID: (not set — will write YOUR_TEAM_ID placeholder; edit the file before shipping)" >&3
  fi

  local ans
  read -r -p "Generate MAS-ExportOptions.plist at '$out'? (Y/n) " ans
  if [[ "${ans:-Y}" =~ ^[Nn]$ ]]; then
    return 1
  fi

  if [[ -f "$out" ]]; then
    local ow
    read -r -p "File already exists. Overwrite? (y/N) " ow
    if [[ ! "${ow:-N}" =~ ^[Yy]$ ]]; then
      return 1
    fi
  fi

  local team_id="${DEVELOPMENT_TEAM:-YOUR_TEAM_ID}"

  info "Generating MAS-ExportOptions.plist: $out"
  /bin/cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
</dict>
</plist>
PLIST

  if [[ "$team_id" == "YOUR_TEAM_ID" ]]; then
    warn "Generated $out with placeholder teamID 'YOUR_TEAM_ID' — edit it (or set DEVELOPMENT_TEAM and pre-flight will catch the mismatch before the next build)."
  fi

  MAS_EXPORT_PLIST="$out"
  return 0
}

autodetect_ios_export_plist_if_needed() {
  # Mirror autodetect_export_plist_if_needed for iOS. Skip Mac-only methods
  # (developer-id, mac-application) when scanning by content. Also skip files
  # already claimed by MAS_EXPORT_PLIST to avoid binding the same plist to
  # both platforms.
  [[ "${ENABLE_IOS:-0}" == "1" ]] || return 0
  is_placeholder "${IOS_EXPORT_PLIST:-}" || return 0

  local conventional="$REPO_ROOT/iOS-ExportOptions.plist"
  if [[ -f "$conventional" ]]; then
    IOS_EXPORT_PLIST="$conventional"
    info "Auto-detected iOS ExportOptions.plist (by name): $IOS_EXPORT_PLIST"
    return 0
  fi

  local matches=() p flat
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # Skip any plist already claimed by MAS_EXPORT_PLIST so the MAS plist isn't
    # accidentally bound to iOS (both use method=app-store-connect).
    if [[ -n "${MAS_EXPORT_PLIST:-}" && "$p" == "$MAS_EXPORT_PLIST" ]]; then
      continue
    fi
    flat="$(/bin/cat "$p" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    if echo "$flat" | /usr/bin/grep -qiE '<key>method</key><string>(developer-id|mac-application)</string>'; then
      continue
    fi
    if echo "$flat" | /usr/bin/grep -qiE '<key>method</key><string>(app-store-connect|release-testing|ad-hoc|enterprise|debugging|development)</string>'; then
      matches+=("$p")
    fi
  done < <(/usr/bin/find "$REPO_ROOT" -maxdepth 1 -type f -name '*.plist' 2>/dev/null | /usr/bin/sort)

  if [[ "${#matches[@]}" -eq 1 ]]; then
    IOS_EXPORT_PLIST="${matches[0]}"
    info "Auto-detected iOS ExportOptions.plist (by contents): $IOS_EXPORT_PLIST"
    return 0
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    warn "Multiple iOS ExportOptions-like plist files found. Pass --ios-export-plist PATH to select one."
    return 0
  fi

  # No conventional plist and no content-scan match — offer to generate one
  # interactively. Falls through to the warn below if non-TTY or declined.
  if maybe_generate_ios_export_plist_interactively; then
    return 0
  fi

  warn "No iOS ExportOptions.plist found. Copy iOS-ExportOptions.plist.example to iOS-ExportOptions.plist and edit, or pass --ios-export-plist PATH."
}

maybe_generate_ios_export_plist_interactively() {
  # Offer to generate a minimal iOS-ExportOptions.plist suitable for App
  # Store / TestFlight exports. Only runs in interactive terminals. Mirrors
  # maybe_generate_mas_export_plist_interactively. YOUR_TEAM_ID placeholder
  # is written when DEVELOPMENT_TEAM is unset; pre-flight teamID checks for
  # the iOS plist are looser today (xcodebuild surfaces the error at archive
  # time), but the placeholder makes the forgotten edit visible to anyone
  # reading the file.
  if [[ ! -t 0 ]]; then
    return 1
  fi

  local out
  out="$REPO_ROOT/iOS-ExportOptions.plist"

  echo "No iOS-ExportOptions.plist was detected." >&3
  echo "I can generate a minimal one for iOS App Store / TestFlight exports." >&3
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "Team ID: $DEVELOPMENT_TEAM" >&3
  else
    echo "Team ID: (not set — will write YOUR_TEAM_ID placeholder; edit the file before shipping)" >&3
  fi

  local ans
  read -r -p "Generate iOS-ExportOptions.plist at '$out'? (Y/n) " ans
  if [[ "${ans:-Y}" =~ ^[Nn]$ ]]; then
    return 1
  fi

  if [[ -f "$out" ]]; then
    local ow
    read -r -p "File already exists. Overwrite? (y/N) " ow
    if [[ ! "${ow:-N}" =~ ^[Yy]$ ]]; then
      return 1
    fi
  fi

  local team_id="${DEVELOPMENT_TEAM:-YOUR_TEAM_ID}"

  info "Generating iOS-ExportOptions.plist: $out"
  /bin/cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
</dict>
</plist>
PLIST

  if [[ "$team_id" == "YOUR_TEAM_ID" ]]; then
    warn "Generated $out with placeholder teamID 'YOUR_TEAM_ID' — edit it before running the iOS archive (xcodebuild will reject the placeholder at archive time)."
  fi

  IOS_EXPORT_PLIST="$out"
  return 0
}

_extract_ue_filepath() {
  # UE serializes FFilePath ini values as (FilePath="/path/to/file"). Strip the
  # struct wrapper if present, otherwise return the value as-is. Tolerates
  # whitespace and the optional quoting Xcode sometimes emits. Regex is held
  # in a variable so bash's [[ =~ ]] parser doesn't choke on the literal
  # parens/brackets in the pattern.
  local v="$1"
  local quoted='^[[:space:]]*\(FilePath="(.*)"\)[[:space:]]*$'
  local unquoted='^[[:space:]]*\(FilePath=([^)]*)\)[[:space:]]*$'
  if [[ "$v" =~ $quoted ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$v" =~ $unquoted ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' "$v"
}

autodetect_asc_credentials_if_needed() {
  # Read App Store Connect API credentials from Config/DefaultEngine.ini if
  # Xcode previously configured them there. The fields Xcode writes are
  # AppStoreConnectKeyID, AppStoreConnectIssuerID, AppStoreConnectKeyPath
  # under [/Script/IOSRuntimeSettings.IOSRuntimeSettings] or its enclosing
  # section. We read them with the existing simple read_ini_value helper —
  # no per-section qualifying since these keys are unique within the file.
  #
  # AppStoreConnectKeyPath is serialized as an FFilePath struct:
  #   AppStoreConnectKeyPath=(FilePath="/Users/.../AuthKey_XXXX.p8")
  # so we run it through _extract_ue_filepath to get the plain path.
  #
  # Fires when either the iOS or Mac App Store upload/validate toggle is set
  # — the same ASC API key serves both platforms.
  local needs_creds=0
  [[ "${IOS_ASC_VALIDATE:-0}" == "1" || "${IOS_ASC_UPLOAD:-0}" == "1" ]] && needs_creds=1
  [[ "${MAS_ASC_VALIDATE:-0}" == "1" || "${MAS_ASC_UPLOAD:-0}" == "1" ]] && needs_creds=1
  [[ "$needs_creds" -eq 1 ]] || return 0

  local engine_ini="$REPO_ROOT/Config/DefaultEngine.ini"
  [[ -f "$engine_ini" ]] || return 0

  local v
  if is_placeholder "${ASC_API_KEY_ID:-}"; then
    v="$(read_ini_value "$engine_ini" "AppStoreConnectKeyID")"
    if [[ -n "$v" ]]; then
      ASC_API_KEY_ID="$v"
      IOS_ASC_API_KEY_ID="$v"
      info "Auto-detected ASC_API_KEY_ID from DefaultEngine.ini: $ASC_API_KEY_ID"
    fi
  fi
  if is_placeholder "${ASC_API_ISSUER:-}"; then
    v="$(read_ini_value "$engine_ini" "AppStoreConnectIssuerID")"
    if [[ -n "$v" ]]; then
      ASC_API_ISSUER="$v"
      IOS_ASC_API_ISSUER="$v"
      info "Auto-detected ASC_API_ISSUER from DefaultEngine.ini"
    fi
  fi
  if is_placeholder "${ASC_API_KEY_PATH:-}"; then
    v="$(read_ini_value "$engine_ini" "AppStoreConnectKeyPath")"
    if [[ -n "$v" ]]; then
      ASC_API_KEY_PATH="$(_extract_ue_filepath "$v")"
      IOS_ASC_API_KEY_PATH="$ASC_API_KEY_PATH"
      info "Auto-detected ASC_API_KEY_PATH from DefaultEngine.ini: $ASC_API_KEY_PATH"
    fi
  fi
}

first_appiconset_name_in_catalog() {
  # Return the first *.appiconset folder name (without suffix) from an asset catalog.
  local catalog_dir="$1"
  [[ -d "$catalog_dir" ]] || { echo ""; return 0; }

  local d
  d="$(/usr/bin/find "$catalog_dir" -maxdepth 1 -type d -name '*.appiconset' -print | /usr/bin/sort | /usr/bin/head -n 1 || true)"
  [[ -n "$d" ]] || { echo ""; return 0; }
  d="$(/usr/bin/basename "$d")"
  echo "${d%.appiconset}"
}

_mirror_appicon_in_catalog() {
  # Ensure $catalog/AppIcon.appiconset exists by mirroring from a named (or
  # auto-detected first) appiconset within $catalog. Idempotent.
  #
  # Why this exists: UE's xcconfig hardcodes
  #   ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon         (XcodeProject.cs:2157)
  # for both UAT BuildCookRun's internal actool invocation and the script's
  # subsequent xcodebuild archive. There is no UE-supported way to change
  # that name. So if the user maintains an appiconset under a different name
  # (e.g. MyAppIcon.appiconset), we mirror it to AppIcon.appiconset
  # alongside so actool finds it where it expects.
  #
  # Returns 0 on success (mirror created or already present), 1 if the
  # catalog has no usable appiconset to mirror from.
  #
  # Args:
  #   $1 = catalog directory absolute path
  #   $2 = explicit appiconset name override (empty = auto-detect first)
  local catalog="$1" override="$2"

  [[ -d "$catalog" ]] || return 0
  [[ -d "$catalog/AppIcon.appiconset" ]] && return 0

  local source_name="$override"
  if is_placeholder "$source_name"; then
    source_name="$(first_appiconset_name_in_catalog "$catalog")"
  fi
  if is_placeholder "$source_name" || [[ ! -d "$catalog/$source_name.appiconset" ]]; then
    return 1
  fi

  /bin/cp -R "$catalog/$source_name.appiconset" "$catalog/AppIcon.appiconset"
  good "Mirrored $catalog/$source_name.appiconset → AppIcon.appiconset (UE's xcconfig hardcodes ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon)"
}

ensure_canonical_appicon_for_platform() {
  # After seed_<platform>_icon_assets (if any) has run, make sure the
  # canonical Build/<Platform>/Resources/Assets.xcassets has an
  # AppIcon.appiconset. This handles users who manage the canonical catalog
  # directly (no source-controlled stage) and have their appiconset named
  # something other than AppIcon — e.g. MyAppIcon.appiconset.
  #
  # Args:
  #   $1 = label for log lines (e.g. "macOS", "iOS")
  #   $2 = platform subdir under Build/ ("Mac", "IOS")
  #   $3 = explicit appiconset name override (e.g. $MACOS_APPICON_SET_NAME)
  local label="$1" platform="$2" override="$3"
  local catalog="$REPO_ROOT/Build/$platform/Resources/Assets.xcassets"

  if ! _mirror_appicon_in_catalog "$catalog" "$override"; then
    if [[ -d "$catalog" ]]; then
      warn "$label catalog at $catalog has no usable appiconset; UE/actool will fail. Add an AppIcon.appiconset (or set the appiconset-name override and re-run)."
    fi
  fi
}

ensure_macos_canonical_appicon() {
  # Mac: only meaningful when we're going to invoke xcodebuild for Mac.
  [[ "$USE_XCODE_EXPORT" == "1" && "${IOS_ONLY:-0}" != "1" ]] || return 0
  ensure_canonical_appicon_for_platform "macOS" "Mac" "${MACOS_APPICON_SET_NAME:-}"
}

ensure_ios_canonical_appicon() {
  [[ "${ENABLE_IOS:-0}" == "1" ]] || return 0
  ensure_canonical_appicon_for_platform "iOS" "IOS" "${IOS_APPICON_SET_NAME:-}"
}

find_first_app_under() {
  # Find the first .app bundle under a root (prefers shallow paths; returns empty if none).
  local root="$1"
  /usr/bin/find "$root" -maxdepth 5 -type d -name '*.app' -print -quit 2>/dev/null || true
}

abspath_existing() {
  # Convert an existing file/dir path to an absolute, physical path.
  # Returns empty string if the target does not exist or cannot be resolved.
  local p="$1"
  [[ -n "$p" ]] || { echo ""; return 0; }
  [[ -e "$p" ]] || { echo ""; return 0; }

  local dir base absdir
  dir="$(/usr/bin/dirname "$p")"
  base="$(/usr/bin/basename "$p")"

  absdir="$(cd "$dir" 2>/dev/null && /bin/pwd -P 2>/dev/null)"
  if [[ -z "$absdir" ]]; then
    echo ""
    return 0
  fi

  echo "$absdir/$base"
}

abspath_from() {
  # Resolve a (possibly relative) path against a base directory.
  # Does not require the target to exist.
  local base="$1"
  local p="$2"
  [[ -n "$p" ]] || { echo ""; return 0; }
  if [[ "$p" == /* ]]; then
    echo "$p"
    return 0
  fi

  local d
  d="$(cd "$base" 2>/dev/null && /bin/pwd -P 2>/dev/null)"
  if [[ -z "$d" ]]; then
    echo ""
    return 0
  fi
  echo "$d/$p"
}

read_ini_value() {
  # first match only; expects Key=Value
  local file="$1"; local key="$2"
  [[ -f "$file" ]] || { echo ""; return 0; }

  local line val
  line="$(/usr/bin/grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | /usr/bin/head -n 1 || true)"
  [[ -n "$line" ]] || { echo ""; return 0; }

  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%%;*}"; val="${val%%#*}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  echo "$val"
}

detect_steam_from_ini() {
  local engine_ini="$REPO_ROOT/Config/DefaultEngine.ini"
  [[ -f "$engine_ini" ]] || return 1

  /usr/bin/grep -qiE "OnlineSubsystemSteam|DefaultPlatformService[[:space:]]*=[[:space:]]*Steam" "$engine_ini" && return 0

  /usr/bin/awk '
    BEGIN{in=0}
    /^\[/ {in=0}
    /^\[\/Script\/OnlineSubsystemSteam\.OnlineSubsystemSteam\]/ {in=1}
    in && /^[[:space:]]*bEnabled[[:space:]]*=[[:space:]]*true/ {found=1}
    END{exit(found?0:1)}
  ' "$engine_ini" 2>/dev/null && return 0

  return 1
}

autodetect_steam_if_needed() {
  if [[ "${CLI_SET_ENABLE_STEAM:-0}" != "1" && "${ENABLE_STEAM:-0}" == "0" ]]; then
    if detect_steam_from_ini; then
      ENABLE_STEAM="1"
      warn "Auto-enabled ENABLE_STEAM=1 (Steam OSS detected in Config/DefaultEngine.ini)."
      warn "This adds security-weakening entitlements: disable-library-validation + allow-dyld-environment-variables."
      warn "To suppress this for a non-Steam build, set ENABLE_STEAM=0 explicitly."

      local engine_ini="$REPO_ROOT/Config/DefaultEngine.ini"
      local appid
      appid="$(read_ini_value "$engine_ini" "SteamDevAppId")"
      [[ -z "$appid" ]] && appid="$(read_ini_value "$engine_ini" "SteamAppId")"
      if [[ -n "$appid" ]]; then
        STEAM_APP_ID="$appid"
        info "Detected Steam App ID from INI: $STEAM_APP_ID"
      fi
    fi
  fi
}

read_steamworks_version_number() {
  # Extract SteamVersionNumber (e.g., 1.63) from Steamworks.build.cs (best-effort).
  local cs="$1"
  [[ -f "$cs" ]] || { echo ""; return 0; }

  # Example line: double SteamVersionNumber = 1.63;
  /usr/bin/awk '
    match($0, /SteamVersionNumber[[:space:]]*=[[:space:]]*[0-9]+\.[0-9]+/) {
      s=substr($0, RSTART, RLENGTH)
      sub(/^.*=/, "", s)
      gsub(/[[:space:]]*/, "", s)
      print s
      exit
    }
  ' "$cs" 2>/dev/null || true
}

steam_version_to_folder() {
  # Convert 1.63 -> Steamv163 (remove dot).
  local v="$1"
  [[ -n "$v" ]] || { echo ""; return 0; }
  local digits
  digits="${v//./}"
  echo "Steamv${digits}"
}

autodetect_steam_dylib_src_from_engine_if_needed() {
  # If Steam is enabled and STEAM_DYLIB_SRC is placeholder, try to locate it inside UE_ROOT.
  # Expected layout:
  #   <UE_ROOT>/Engine/Source/ThirdParty/Steamworks/Steamv163/sdk/redistributable_bin/osx/libsteam_api.dylib
  #
  # We do NOT assume a specific UE version; we derive everything from UE_ROOT.

  [[ "${ENABLE_STEAM:-0}" == "1" ]] || return 0
  is_placeholder "${STEAM_DYLIB_SRC:-}" || return 0

  local steam_root cs ver folder candidate
  steam_root="$UE_ROOT/Engine/Source/ThirdParty/Steamworks"
  cs="$steam_root/Steamworks.build.cs"

  if [[ ! -d "$steam_root" ]]; then
    # Some engine installs may omit ThirdParty sources; don't fail here.
    warn "ENABLE_STEAM=1 but Steamworks ThirdParty folder not found under UE_ROOT: $steam_root"
    return 0
  fi

  if [[ ! -f "$cs" ]]; then
    warn "Steamworks.build.cs not found (cannot auto-detect Steam SDK version): $cs"
    return 0
  fi

  ver="$(read_steamworks_version_number "$cs")"
  folder="$(steam_version_to_folder "$ver")"

  if [[ -z "$folder" ]]; then
    warn "Could not parse SteamVersionNumber from: $cs"
    return 0
  fi

  candidate="$steam_root/$folder/sdk/redistributable_bin/osx/libsteam_api.dylib"
  if [[ -f "$candidate" ]]; then
    STEAM_DYLIB_SRC="$candidate"
    info "Auto-detected STEAM_DYLIB_SRC from UE_ROOT ($folder): $STEAM_DYLIB_SRC"
    return 0
  fi

  # Fallback: if expected folder isn't present, try to find any matching dylib under Steamworks.
  local found
  found="$(/usr/bin/find "$steam_root" -maxdepth 6 -type f -name 'libsteam_api.dylib' -path '*/redistributable_bin/osx/*' -print -quit 2>/dev/null || true)"
  if [[ -n "$found" && -f "$found" ]]; then
    STEAM_DYLIB_SRC="$found"
    info "Auto-detected STEAM_DYLIB_SRC by search under Steamworks: $STEAM_DYLIB_SRC"
    return 0
  fi

  warn "ENABLE_STEAM=1 but could not locate libsteam_api.dylib under: $steam_root"
  warn "Expected (based on SteamVersionNumber=$ver): $candidate"
  warn "Set STEAM_DYLIB_SRC explicitly (--steam-dylib-src or env/USER CONFIG) if your layout differs."
}

autodetect_ue_root_if_needed() {
  # Best-effort UE_ROOT detection for Epic Games Launcher installs on macOS.
  # Common path: /Users/Shared/Epic Games/UE_X.Y
  # We only accept candidates that look complete (contain Engine/Binaries/Mac).

  if ! is_placeholder "${UE_ROOT:-}"; then
    return 0
  fi

  local base_dir="/Users/Shared/Epic Games"
  [[ -d "$base_dir" ]] || return 0

  local candidates=()
  local d

  # Prefer UE_* folders but still validate by required subfolder.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ -d "$d/Engine/Binaries/Mac" ]]; then
      candidates+=("$d")
    fi
  done < <(/usr/bin/find "$base_dir" -maxdepth 1 -type d -name 'UE_*' 2>/dev/null | /usr/bin/sort)

  # If no UE_* candidates, do a slightly broader scan for engine-looking folders.
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      if [[ -d "$d/Engine/Binaries/Mac" ]]; then
        candidates+=("$d")
      fi
    done < <(/usr/bin/find "$base_dir" -maxdepth 2 -type d -name 'Engine' 2>/dev/null | /usr/bin/sed 's#/Engine$##' | /usr/bin/sort -u)
  fi

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    UE_ROOT="${candidates[0]}"
    info "UE_ROOT not set — auto-detected engine: $UE_ROOT"
    return 0
  fi

  if [[ "${#candidates[@]}" -gt 1 ]]; then
    echo "== UE_ROOT not set — found multiple Unreal Engine installs under: $base_dir ==" >&3
    local i=1
    for d in "${candidates[@]}"; do
      echo "  [$i] $d" >&3
      i=$((i+1))
    done

    # If running in a non-interactive context, don't guess.
    if [[ ! -t 0 ]]; then
      die "Multiple Unreal Engine installs found. Re-run with --ue-root PATH (or set UE_ROOT env var) to select one."
    fi

    local choice
    read -r -p "Select engine [1]: " choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#candidates[@]}" ]]; then
      UE_ROOT="${candidates[$((choice-1))]}"
      info "Selected UE_ROOT: $UE_ROOT"
      return 0
    fi

    die "Invalid selection '$choice'. Re-run and choose a number 1-${#candidates[@]}, or pass --ue-root PATH."
  fi
}

#
# Normalize config from .env / environment / CLI.
# Only provide internal fallbacks for optional values.
REPO_ROOT="${REPO_ROOT:-}"
UPROJECT_NAME="${UPROJECT_NAME:-}"
XCODE_WORKSPACE="${XCODE_WORKSPACE:-}"
XCODE_SCHEME="${XCODE_SCHEME:-}"
# BUILD_DIR holds script-side outputs: .xcarchive, export dir, ZIP, DMG.
# Default sits under Saved/ (UE's documented dumping ground for derived artifacts);
# Build/{Platform}/ is reserved for committed source-controlled inputs.
# UAT BuildCookRun's -archivedirectory is derived as the parent so that UAT's
# automatic /<Platform>/ suffix lands inside BUILD_DIR.
BUILD_DIR_REL="${BUILD_DIR_REL:-Saved/Packages/Mac}"
LOG_DIR_REL="${LOG_DIR_REL:-Saved/Logs}"

SHORT_NAME="${SHORT_NAME:-}"
LONG_NAME="${LONG_NAME:-}"

USE_XCODE_EXPORT="${USE_XCODE_EXPORT:-1}"
REGEN_PROJECT_FILES="${REGEN_PROJECT_FILES:-1}"
SEED_APPLE_LAUNCHSCREEN_COMPAT="${SEED_APPLE_LAUNCHSCREEN_COMPAT:-1}"
SEED_MAC_INFO_TEMPLATE_PLIST="${SEED_MAC_INFO_TEMPLATE_PLIST:-1}"
# CFBundleVersion strategy. Default OFF (Path B): the script auto-bumps an
# integer CFBUNDLE_VERSION every build and persists it to .env on success.
# When ON (Path A): the script seeds Build/Mac/<Project>.PackageVersionCounter
# and a project-level UpdateVersionAfterBuild.sh override, then leaves
# CFBundleVersion to UE. Mutually exclusive with the auto-bump.
USE_UE_PACKAGE_VERSION_COUNTER="${USE_UE_PACKAGE_VERSION_COUNTER:-0}"
CLEAN_BUILD_DIR="${CLEAN_BUILD_DIR:-0}"
DRY_RUN="${DRY_RUN:-0}"
PRINT_CONFIG="${PRINT_CONFIG:-0}"
BUILD_TYPE="${BUILD_TYPE:-}"
NOTARIZE="${NOTARIZE:-}"

UE_ROOT="${UE_ROOT:-}"
UAT_SCRIPTS_SUBPATH="${UAT_SCRIPTS_SUBPATH:-Engine/Build/BatchFiles}"
UE_EDITOR_SUBPATH="${UE_EDITOR_SUBPATH:-Engine/Binaries/Mac/UnrealEditor.app/Contents/MacOS/UnrealEditor}"

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
EXPORT_PLIST="${EXPORT_PLIST:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

ENABLE_STEAM="${ENABLE_STEAM:-0}"
STEAM_APP_ID="${STEAM_APP_ID:-480}"
WRITE_STEAM_APPID="${WRITE_STEAM_APPID:-0}"
STEAM_DYLIB_SRC="${STEAM_DYLIB_SRC:-}"

MACOS_APPICON_SET_NAME="${MACOS_APPICON_SET_NAME:-}"

# -----------------------------------------------------------------------------
# Distribution dispatcher (the central per-platform branch selector)
#
# These two variables decide WHICH pipeline runs for each platform. Every
# downstream platform-specific check (entitlements, signing, ExportOptions
# method, upload tooling) should consult them rather than reading the legacy
# ENABLE_IOS / IOS_ONLY flags. Legacy flags remain supported and are resolved
# into these dispatchers below — see resolve_distribution_flags().
#
#   MAC_DISTRIBUTION=
#     developer-id   (default) Direct Distribution: Developer ID Application
#                    signing, hardened runtime, notarized + stapled. Steam is
#                    allowed here (and only here). Game Center is NOT
#                    available on this channel — AMFI rejects
#                    com.apple.developer.game-center on Developer-ID-signed
#                    Mac apps at exec, regardless of notarization.
#     app-store      Mac App Store: Apple Distribution signing, App Sandbox,
#                    Game Center allowed, Steam forbidden. Mirrors the iOS
#                    pipeline: xcodebuild archive + export under automatic
#                    provisioning, then `xcrun altool -t macos` to validate /
#                    upload the exported .pkg installer to App Store
#                    Connect. (Xcode's app-store-connect export on macOS
#                    produces a signed .pkg installer — not a .app bundle —
#                    that wraps the signed app.) No ZIP, no DMG, no
#                    notarize, no staple — ASC review is the equivalent gate.
#     off            Skip Mac entirely (iOS-only run).
#
#   IOS_DISTRIBUTION=
#     off            (default) Skip iOS.
#     app-store      Run the iOS pipeline (UAT → archive → IPA → optional ASC
#                    validate/upload). iOS has no other distribution channel
#                    in the US, so this is the only non-off value.
#
# Compatibility matrix is enforced in validate_distribution_compatibility():
#   - MAC_DISTRIBUTION=off requires IOS_DISTRIBUTION=app-store
#   - MAC_DISTRIBUTION=app-store + ENABLE_STEAM=1 → rejected (MAS forbids the
#     Steam entitlements outright)
#   - MAC_DISTRIBUTION=developer-id + ENABLE_GAME_CENTER=1 and no iOS pass →
#     rejected (Mac Game Center is structurally a MAS feature; see docs/gotchas.md)
# -----------------------------------------------------------------------------
MAC_DISTRIBUTION="${MAC_DISTRIBUTION:-developer-id}"
IOS_DISTRIBUTION="${IOS_DISTRIBUTION:-off}"

# Legacy flags. Kept for back-compat with existing .env files and CI configs;
# resolve_distribution_flags() reconciles them with MAC_DISTRIBUTION /
# IOS_DISTRIBUTION after CLI parsing. New code should consult the dispatcher
# variables directly.
ENABLE_IOS="${ENABLE_IOS:-0}"
IOS_ONLY="${IOS_ONLY:-0}"
IOS_WORKSPACE="${IOS_WORKSPACE:-}"
IOS_SCHEME="${IOS_SCHEME:-}"
IOS_EXPORT_PLIST="${IOS_EXPORT_PLIST:-}"
IOS_APPICON_SET_NAME="${IOS_APPICON_SET_NAME:-}"
IOS_MARKETING_VERSION="${IOS_MARKETING_VERSION:-}"

# App Store Connect API credentials (xcrun altool — NOT notarytool; different
# tools, different services). altool talks to ASC's submission/validation
# API and is the documented path for both IPA (iOS) and .pkg (Mac App Store) uploads.
# It auths via an API key (.p8 file + key ID + issuer UUID), distinct from
# the keychain profile notarytool uses for Mac Developer ID notarization.
#
# A single Apple Developer account uses one ASC API key for both iOS and Mac
# uploads — ASC_API_KEY_ID/ISSUER/PATH are the canonical names, shared across
# the iOS and Mac App Store pipelines. The legacy IOS_ASC_API_* aliases are
# still honored (see resolve_asc_credential_aliases() below) so existing
# .env / CI configs keep working.
ASC_API_KEY_ID="${ASC_API_KEY_ID:-}"
ASC_API_ISSUER="${ASC_API_ISSUER:-}"
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}"

# Per-platform validate/upload toggles. The validate/upload action runs only
# when the platform's toggle is on (MAS_ASC_* for Mac App Store, IOS_ASC_*
# for iOS); both consume the shared ASC_API_* creds.
IOS_ASC_VALIDATE="${IOS_ASC_VALIDATE:-0}"
IOS_ASC_UPLOAD="${IOS_ASC_UPLOAD:-0}"
MAS_ASC_VALIDATE="${MAS_ASC_VALIDATE:-0}"
MAS_ASC_UPLOAD="${MAS_ASC_UPLOAD:-0}"

# Legacy iOS-prefixed ASC credential variables. Kept for back-compat; resolved
# into ASC_API_* by resolve_asc_credential_aliases() after CLI parsing.
IOS_ASC_API_KEY_ID="${IOS_ASC_API_KEY_ID:-}"
IOS_ASC_API_ISSUER="${IOS_ASC_API_ISSUER:-}"
IOS_ASC_API_KEY_PATH="${IOS_ASC_API_KEY_PATH:-}"

# Mac App Store ExportOptions.plist path (separate from EXPORT_PLIST which is
# Developer ID-only — the two have different `method` values and Apple rejects
# the wrong one at export time).
MAS_EXPORT_PLIST="${MAS_EXPORT_PLIST:-}"

ENABLE_ZIP="${ENABLE_ZIP:-}"
ENABLE_DMG="${ENABLE_DMG:-0}"
FANCY_DMG="${FANCY_DMG:-0}"
DMG_NAME="${DMG_NAME:-}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-}"
DMG_OUTPUT_DIR="${DMG_OUTPUT_DIR:-}"

VERSION_MODE="${VERSION_MODE:-NONE}"
VERSION_STRING="${VERSION_STRING:-}"
VERSION_CONTENT_DIR="${VERSION_CONTENT_DIR:-BuildInfo}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
ENABLE_GAME_MODE="${ENABLE_GAME_MODE:-}"
ENABLE_GAME_CENTER="${ENABLE_GAME_CENTER:-}"
APP_CATEGORY="${APP_CATEGORY:-}"
CFBUNDLE_VERSION="${CFBUNDLE_VERSION:-}"


# -----------------------------------------------------------------------------
# Command-line flag overrides (highest priority)
# -----------------------------------------------------------------------------

usage() {
  cat >&3 <<'USAGE'
Usage:
  ./ship.sh [options]

Options (highest priority):
  --repo-root PATH
  --uproject FILE_OR_PATH            (e.g. MyGame.uproject)
  --ue-root PATH
  --xcode-workspace FILE_OR_PATH     (e.g. "MyGame (Mac).xcworkspace")
  --xcode-scheme NAME
  --build-dir PATH                   (script-side outputs; default: Saved/Packages/Mac.
                                      UAT BuildCookRun's -archivedirectory is
                                      derived as the parent so its /<Platform>/
                                      output lands inside this dir.)
  --development-team TEAMID
  --sign-identity "Developer ID Application: ... (TEAMID)"
  --export-plist PATH
  --notary-profile NAME

  --short-name NAME
  --long-name NAME

  --xcode-export / --no-xcode-export
  --regen-project-files / --no-regen-project-files
                                     run GenerateProjectFiles.sh before xcodebuild
                                     (default: enabled when --xcode-export)
  --seed-apple-launchscreen-compat / --no-seed-apple-launchscreen-compat
                                     copy engine's LaunchScreen.storyboardc into
                                     Build/Apple/Resources/Interface/ if absent,
                                     so Mac's launch-screen path priority list
                                     short-circuits before Xcode tries to compile
                                     a consumer-supplied iOS .storyboard source
                                     (default: enabled)
  --seed-mac-info-template-plist / --no-seed-mac-info-template-plist
                                     copy engine's Info.Template.plist into
                                     Build/Mac/Resources/ if absent. UE merges
                                     this template into the final Info.plist;
                                     this is the canonical home for
                                     LSSupportsGameMode / GCSupportsGameMode and
                                     any other static plist keys (default: enabled)
  --use-ue-package-version-counter / --no-use-ue-package-version-counter
                                     opt into UE's canonical CFBundleVersion path
                                     (Path A): seeds Build/Mac/<Project>.PackageVersionCounter
                                     and a project-level
                                     Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh
                                     override (sanctioned at AppleToolChain.cs:394-397)
                                     that strips the engine's Build.version
                                     Changelist (e.g. 51494982) from CFBundleVersion.
                                     Mutually exclusive with the default auto-bump.
                                     (default: disabled — the script's auto-bump
                                     of CFBUNDLE_VERSION wins instead)
  --clean-build-dir / --no-clean-build-dir
  --dry-run / --no-dry-run
  --print-config / --no-print-config

  --steam / --no-steam
  --write-steam-appid / --no-write-steam-appid
  --steam-app-id ID
  --steam-dylib-src PATH

  --macos-appicon-set-name NAME      name of the *.appiconset to mirror to
                                     "AppIcon" inside Build/Mac/Resources/Assets.xcassets
                                     (UE's xcconfig hardcodes the lookup
                                     name to "AppIcon"). Auto-detects the
                                     first appiconset in the catalog if unset.

  --mac-distribution VALUE           macOS distribution channel:
                                       developer-id (default) — Direct
                                         Distribution (Developer ID, hardened
                                         runtime, notarized + stapled). Steam
                                         allowed; Game Center not available
                                         (AMFI rejects it on this channel).
                                       app-store — Mac App Store (Apple
                                         Distribution + App Sandbox + ASC
                                         upload, Game Center allowed, Steam
                                         forbidden). Mirrors iOS: xcodebuild
                                         archive + export under automatic
                                         provisioning, then xcrun altool
                                         -t macos to validate/upload. No
                                         notarize/staple/ZIP/DMG.
                                       off — skip Mac entirely (iOS-only run).
  --ios-distribution VALUE           iOS distribution channel:
                                       off (default) — skip iOS.
                                       app-store — run the iOS pipeline
                                         (UAT → archive → IPA → optional ASC
                                         upload). No other channel exists for
                                         iOS in the US.

  --ios / --no-ios                   enable iOS pass after the Mac pipeline
                                     (legacy alias for --ios-distribution
                                     app-store; default: off)
  --ios-only                         skip Mac entirely and run only iOS;
                                     legacy alias for "--mac-distribution off
                                     --ios-distribution app-store". Does not
                                     require SIGN_IDENTITY.
  --ios-workspace FILE_OR_PATH       (e.g. "MyGame (iOS).xcworkspace")
  --ios-scheme NAME                  iOS Xcode scheme (auto-detected if unset)
  --ios-export-plist PATH            iOS-ExportOptions.plist path
                                     (auto-detected; conventional name
                                     "iOS-ExportOptions.plist")
  --ios-appicon-set-name NAME        same as --macos-appicon-set-name but for
                                     Build/IOS/Resources/Assets.xcassets
  --ios-marketing-version STRING     CFBundleShortVersionString for iOS only
                                     (when not set, MARKETING_VERSION applies
                                     to both platforms)
  --ios-validate-ipa                 validate the IPA via xcrun altool
                                     --validate-app -t ios (App Store Connect;
                                     NOT notarytool — different tool, different
                                     service)
  --ios-upload-ipa                   upload the IPA via xcrun altool
                                     --upload-app -t ios; implies
                                     --ios-validate-ipa
  --mas-export-plist PATH            Mac App Store ExportOptions.plist path
                                     (auto-detected from
                                     "MAS-ExportOptions.plist" in repo root)
  --mas-validate-app                 validate the exported .pkg installer
                                     via xcrun altool --validate-app -t macos
                                     (Mac App Store, uses
                                     MAC_DISTRIBUTION=app-store; Xcode's
                                     app-store-connect export produces a
                                     signed .pkg, not a .app)
  --mas-upload-app                   upload the exported .pkg installer via
                                     xcrun altool --upload-app -t macos;
                                     implies --mas-validate-app
  --asc-api-key-id ID                App Store Connect API key ID (10-char,
                                     shared between iOS and Mac App Store
                                     uploads — one key per developer account)
  --asc-api-issuer UUID              ASC API issuer UUID
  --asc-api-key-path PATH            path to the .p8 API key file
                                     (auto-detected from
                                     Config/DefaultEngine.ini's
                                     AppStoreConnectKeyID/IssuerID/KeyPath
                                     fields if Xcode wrote them)
  --ios-asc-api-key-id ID            (legacy alias for --asc-api-key-id)
  --ios-asc-api-issuer UUID          (legacy alias for --asc-api-issuer)
  --ios-asc-api-key-path PATH        (legacy alias for --asc-api-key-path)

  --zip / --no-zip
  --dmg / --no-dmg
  --fancy-dmg / --no-fancy-dmg
  --dmg-name NAME
  --dmg-volume-name NAME
  --dmg-output-dir PATH

  --build-type shipping|development
  --notarize / --no-notarize

  --version-mode NONE|MANUAL|DATETIME|HYBRID
  --version-string STRING
  --version-content-dir DIR          (subdirectory under Content/, default: BuildInfo)
  --marketing-version STRING         (CFBundleShortVersionString stamped into xcconfig, default: 1.0.0)
  --game-mode / --no-game-mode       (stamp LSSupportsGameMode + GCSupportsGameMode in xcconfig, default: YES)
  --game-center / --no-game-center   Seed Build/<Platform>/Resources/<project>.entitlements
                                     with com.apple.developer.game-center, write
                                     bEnableGameCenterSupport=True to DefaultEngine.ini,
                                     and pass CODE_SIGN_ENTITLEMENTS=<path> to xcodebuild
                                     archive (UBT's intermediate entitlements file is
                                     ignored under automatic signing). Eligible
                                     channels: iOS (IOS_DISTRIBUTION=app-store) and Mac
                                     App Store (MAC_DISTRIBUTION=app-store). Not
                                     available for MAC_DISTRIBUTION=developer-id —
                                     AMFI rejects com.apple.developer.game-center on
                                     Developer-ID-signed Mac apps at exec, regardless
                                     of notarization. Default: unset (leaves things
                                     alone).
  --app-category STRING              (INFOPLIST_KEY_LSApplicationCategoryType, e.g. public.app-category.games)
  --set-cfbundle-version STRING      set CFBundleVersion to STRING for this build
                                     AND persist it to .env as the new baseline.
                                     Future auto-bump builds will resume from
                                     STRING. Use to reset the counter or pin to
                                     a CI-supplied value (e.g. $GITHUB_RUN_NUMBER).
                                     Without this flag, the script auto-bumps
                                     CFBUNDLE_VERSION as an integer every build
                                     (default behavior; first build ships 1).
  --bump-major / --bump-minor / --bump-patch
                                     bump VERSION_STRING from .env or --version-string;
                                     implies VERSION_MODE=MANUAL if not already set

  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;

    --repo-root)            REPO_ROOT="$2"; shift 2 ;;
    --uproject)
      # Resolve immediately: absolute path → set both UPROJECT_PATH and UPROJECT_NAME.
      # Bare filename or relative path → set UPROJECT_NAME only; path resolved later.
      if [[ "$2" == /* ]]; then
        UPROJECT_PATH="$2"
        UPROJECT_NAME="$(/usr/bin/basename "$2")"
      else
        UPROJECT_NAME="$2"
        UPROJECT_PATH=""
      fi
      shift 2 ;;
    --ue-root)              UE_ROOT="$2"; shift 2 ;;
    --xcode-workspace)      XCODE_WORKSPACE="$2"; shift 2 ;;
    --xcode-scheme)         XCODE_SCHEME="$2"; shift 2 ;;
    --build-dir)            BUILD_DIR_REL="$2"; shift 2 ;;

    --development-team)     DEVELOPMENT_TEAM="$2"; shift 2 ;;
    --sign-identity)        SIGN_IDENTITY="$2"; shift 2 ;;
    --export-plist)         EXPORT_PLIST="$2"; shift 2 ;;
    --notary-profile)       NOTARY_PROFILE="$2"; shift 2 ;;

    --short-name)           SHORT_NAME="$2"; shift 2 ;;
    --long-name)            LONG_NAME="$2"; shift 2 ;;

    --xcode-export)         USE_XCODE_EXPORT="1"; shift ;;
    --no-xcode-export)      USE_XCODE_EXPORT="0"; shift ;;
    --regen-project-files)    REGEN_PROJECT_FILES="1"; shift ;;
    --no-regen-project-files) REGEN_PROJECT_FILES="0"; shift ;;
    --seed-apple-launchscreen-compat)    SEED_APPLE_LAUNCHSCREEN_COMPAT="1"; shift ;;
    --no-seed-apple-launchscreen-compat) SEED_APPLE_LAUNCHSCREEN_COMPAT="0"; shift ;;
    --seed-mac-info-template-plist)      SEED_MAC_INFO_TEMPLATE_PLIST="1"; shift ;;
    --no-seed-mac-info-template-plist)   SEED_MAC_INFO_TEMPLATE_PLIST="0"; shift ;;
    --use-ue-package-version-counter)    USE_UE_PACKAGE_VERSION_COUNTER="1"; shift ;;
    --no-use-ue-package-version-counter) USE_UE_PACKAGE_VERSION_COUNTER="0"; shift ;;
    --clean-build-dir)      CLEAN_BUILD_DIR="1"; shift ;;
    --no-clean-build-dir)   CLEAN_BUILD_DIR="0"; shift ;;
    --dry-run)              DRY_RUN="1"; shift ;;
    --no-dry-run)           DRY_RUN="0"; shift ;;
    --print-config)         PRINT_CONFIG="1"; shift ;;
    --no-print-config)      PRINT_CONFIG="0"; shift ;;

    --steam)                ENABLE_STEAM="1"; CLI_SET_ENABLE_STEAM=1; shift ;;
    --no-steam)             ENABLE_STEAM="0"; CLI_SET_ENABLE_STEAM=1; shift ;;
    --write-steam-appid)    WRITE_STEAM_APPID="1"; shift ;;
    --no-write-steam-appid) WRITE_STEAM_APPID="0"; shift ;;
    --steam-app-id)         STEAM_APP_ID="$2"; shift 2 ;;
    --steam-dylib-src)      STEAM_DYLIB_SRC="$2"; shift 2 ;;

    --macos-appicon-set-name) MACOS_APPICON_SET_NAME="$2"; shift 2 ;;

    --mac-distribution)       MAC_DISTRIBUTION="$2"; CLI_SET_MAC_DISTRIBUTION=1; shift 2 ;;
    --ios-distribution)       IOS_DISTRIBUTION="$2"; CLI_SET_IOS_DISTRIBUTION=1; shift 2 ;;

    --ios)                    ENABLE_IOS="1"; shift ;;
    --no-ios)                 ENABLE_IOS="0"; shift ;;
    --ios-only)               IOS_ONLY="1"; ENABLE_IOS="1"; shift ;;
    --ios-workspace)          IOS_WORKSPACE="$2"; shift 2 ;;
    --ios-scheme)             IOS_SCHEME="$2"; shift 2 ;;
    --ios-export-plist)       IOS_EXPORT_PLIST="$2"; shift 2 ;;
    --ios-appicon-set-name)   IOS_APPICON_SET_NAME="$2"; shift 2 ;;
    --ios-marketing-version)  IOS_MARKETING_VERSION="$2"; shift 2 ;;
    --ios-validate-ipa)       IOS_ASC_VALIDATE="1"; shift ;;
    --ios-upload-ipa)         IOS_ASC_UPLOAD="1"; IOS_ASC_VALIDATE="1"; shift ;;
    --mas-export-plist)       MAS_EXPORT_PLIST="$2"; shift 2 ;;
    --mas-validate-app)       MAS_ASC_VALIDATE="1"; shift ;;
    --mas-upload-app)         MAS_ASC_UPLOAD="1"; MAS_ASC_VALIDATE="1"; shift ;;
    # Generic ASC credentials (shared by iOS + Mac App Store uploads).
    --asc-api-key-id)         ASC_API_KEY_ID="$2"; shift 2 ;;
    --asc-api-issuer)         ASC_API_ISSUER="$2"; shift 2 ;;
    --asc-api-key-path)       ASC_API_KEY_PATH="$2"; shift 2 ;;
    # Legacy iOS-prefixed ASC credential flags (still honored; resolved into
    # ASC_API_* by resolve_asc_credential_aliases()).
    --ios-asc-api-key-id)     IOS_ASC_API_KEY_ID="$2"; shift 2 ;;
    --ios-asc-api-issuer)     IOS_ASC_API_ISSUER="$2"; shift 2 ;;
    --ios-asc-api-key-path)   IOS_ASC_API_KEY_PATH="$2"; shift 2 ;;

    --zip)                  ENABLE_ZIP="1"; shift ;;
    --no-zip)               ENABLE_ZIP="0"; shift ;;
    --dmg)                  ENABLE_DMG="1"; shift ;;
    --no-dmg)               ENABLE_DMG="0"; shift ;;
    --fancy-dmg)            FANCY_DMG="1"; shift ;;
    --no-fancy-dmg)         FANCY_DMG="0"; shift ;;
    --dmg-name)             DMG_NAME="$2"; shift 2 ;;
    --dmg-volume-name)      DMG_VOLUME_NAME="$2"; shift 2 ;;
    --dmg-output-dir)       DMG_OUTPUT_DIR="$2"; shift 2 ;;

    --build-type)           BUILD_TYPE="$2"; shift 2 ;;
    --notarize)             NOTARIZE="yes"; shift ;;
    --no-notarize)          NOTARIZE="no"; shift ;;

    --version-mode)             VERSION_MODE="$2"; shift 2 ;;
    --version-string)           VERSION_STRING="$2"; shift 2 ;;
    --version-content-dir)      VERSION_CONTENT_DIR="$2"; shift 2 ;;
    --marketing-version)        MARKETING_VERSION="$2"; shift 2 ;;
    --game-mode)                ENABLE_GAME_MODE="1"; shift ;;
    --no-game-mode)             ENABLE_GAME_MODE="0"; shift ;;
    --game-center)              ENABLE_GAME_CENTER="1"; shift ;;
    --no-game-center)           ENABLE_GAME_CENTER="0"; shift ;;
    --app-category)             APP_CATEGORY="$2"; shift 2 ;;
    --set-cfbundle-version)     CFBUNDLE_VERSION="$2"; CLI_SET_CFBUNDLE_VERSION=1; shift 2 ;;
    --bump-major|--bump-minor|--bump-patch)
      if is_placeholder "${VERSION_STRING:-}"; then
        die "$1 requires a base version. Set VERSION_STRING in .env or pass --version-string X.Y.Z before $1."
      fi
      VERSION_STRING="$(bump_semver "${1#--bump-}" "$VERSION_STRING")"
      if [[ "$VERSION_MODE" == "NONE" ]]; then VERSION_MODE="MANUAL"; fi
      _VERSION_BUMPED=1
      shift ;;


    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

# -----------------------------------------------------------------------------
# Distribution dispatcher resolution
#
# Reconcile legacy ENABLE_IOS / IOS_ONLY with the new MAC_DISTRIBUTION /
# IOS_DISTRIBUTION variables. The dispatcher is the source of truth for every
# downstream decision; the legacy flags are kept in sync for back-compat with
# the existing condition-checks scattered through the pipeline.
#
# Precedence (highest to lowest):
#   1. CLI flags (--mac-distribution / --ios-distribution) — explicit user intent
#   2. Legacy flags (IOS_ONLY=1, ENABLE_IOS=1) — promote to the dispatcher
#   3. Defaults (developer-id / off)
#
# After this function runs, MAC_DISTRIBUTION and IOS_DISTRIBUTION are
# authoritative, and ENABLE_IOS / IOS_ONLY are derived from them so existing
# checks (e.g. `if [[ "$IOS_ONLY" == "1" ]]`) still resolve correctly.
# -----------------------------------------------------------------------------
resolve_distribution_flags() {
  # Step 1: Promote legacy flags into the dispatcher, but only when the CLI
  # didn't explicitly set the dispatcher (CLI wins outright).
  if [[ "${CLI_SET_MAC_DISTRIBUTION:-0}" != "1" && "${IOS_ONLY:-0}" == "1" ]]; then
    MAC_DISTRIBUTION="off"
  fi
  if [[ "${CLI_SET_IOS_DISTRIBUTION:-0}" != "1" ]]; then
    if [[ "${IOS_ONLY:-0}" == "1" || "${ENABLE_IOS:-0}" == "1" ]]; then
      IOS_DISTRIBUTION="app-store"
    fi
  fi

  # Step 2: Project the dispatcher back onto the legacy flags so existing
  # conditional checks ($IOS_ONLY, $ENABLE_IOS) keep working unchanged.
  if [[ "$MAC_DISTRIBUTION" == "off" ]]; then
    IOS_ONLY="1"
  else
    IOS_ONLY="0"
  fi
  if [[ "$IOS_DISTRIBUTION" == "app-store" ]]; then
    ENABLE_IOS="1"
  else
    ENABLE_IOS="0"
  fi
}

# -----------------------------------------------------------------------------
# Distribution compatibility validator
#
# Enforces the rules from the dispatcher comment block. Each rule corresponds
# to a hard incompatibility that would otherwise produce a broken build or a
# binary the OS will refuse to run. See docs/configuration.md "Distribution
# channels" and docs/gotchas.md for the underlying reasoning.
# -----------------------------------------------------------------------------
validate_distribution_compatibility() {
  case "$MAC_DISTRIBUTION" in
    developer-id|app-store|off) ;;
    *) die "MAC_DISTRIBUTION must be one of: developer-id, app-store, off (got: '$MAC_DISTRIBUTION')" ;;
  esac
  case "$IOS_DISTRIBUTION" in
    off|app-store) ;;
    *) die "IOS_DISTRIBUTION must be one of: off, app-store (got: '$IOS_DISTRIBUTION')" ;;
  esac

  if [[ "$MAC_DISTRIBUTION" == "off" && "$IOS_DISTRIBUTION" == "off" ]]; then
    die "Nothing to build: MAC_DISTRIBUTION=off and IOS_DISTRIBUTION=off. Set MAC_DISTRIBUTION (developer-id) or IOS_DISTRIBUTION (app-store), or use --ios / --ios-only."
  fi

  if [[ "$MAC_DISTRIBUTION" == "app-store" && "${ENABLE_STEAM:-0}" == "1" ]]; then
    die "MAC_DISTRIBUTION=app-store is incompatible with ENABLE_STEAM=1. The Steam entitlements (com.apple.security.cs.disable-library-validation and com.apple.security.cs.allow-dyld-environment-variables) are forbidden by Mac App Store review. Pick one: a Direct Distribution build with Steam (MAC_DISTRIBUTION=developer-id, the default), or a Mac App Store build without Steam."
  fi

  if [[ "$MAC_DISTRIBUTION" == "developer-id" && "${ENABLE_GAME_CENTER:-}" == "1" && "$IOS_DISTRIBUTION" != "app-store" ]]; then
    die "MAC_DISTRIBUTION=developer-id is incompatible with ENABLE_GAME_CENTER=1. Mac Game Center is structurally a Mac App Store feature — AMFI rejects com.apple.developer.game-center on Developer-ID-signed Mac apps at exec, regardless of notarization. For Mac Game Center, use MAC_DISTRIBUTION=app-store. For iOS Game Center on this run, also pass --ios."
  fi
}

# -----------------------------------------------------------------------------
# ASC credential alias resolution
#
# A single Apple Developer account has one App Store Connect API key, used by
# both iOS IPA uploads and Mac App Store .pkg uploads. The canonical variable
# names are ASC_API_KEY_ID / ASC_API_ISSUER / ASC_API_KEY_PATH; the legacy
# IOS_ASC_API_* names are still honored. Precedence:
#
#   1. ASC_API_* if set (either env/.env or --asc-api-* CLI flag)
#   2. IOS_ASC_API_* (legacy) as a fallback
#
# After this runs, ASC_API_* is authoritative everywhere; the IOS_ASC_API_*
# variables are kept in sync for any code still reading them and for the
# print_config view.
# -----------------------------------------------------------------------------
resolve_asc_credential_aliases() {
  if is_placeholder "${ASC_API_KEY_ID:-}" && ! is_placeholder "${IOS_ASC_API_KEY_ID:-}"; then
    ASC_API_KEY_ID="$IOS_ASC_API_KEY_ID"
  fi
  if is_placeholder "${ASC_API_ISSUER:-}" && ! is_placeholder "${IOS_ASC_API_ISSUER:-}"; then
    ASC_API_ISSUER="$IOS_ASC_API_ISSUER"
  fi
  if is_placeholder "${ASC_API_KEY_PATH:-}" && ! is_placeholder "${IOS_ASC_API_KEY_PATH:-}"; then
    ASC_API_KEY_PATH="$IOS_ASC_API_KEY_PATH"
  fi
  # Project back so legacy reads stay consistent.
  IOS_ASC_API_KEY_ID="$ASC_API_KEY_ID"
  IOS_ASC_API_ISSUER="$ASC_API_ISSUER"
  IOS_ASC_API_KEY_PATH="$ASC_API_KEY_PATH"
}

resolve_distribution_flags
validate_distribution_compatibility
resolve_asc_credential_aliases

# If REPO_ROOT is still a placeholder/empty, assume this script lives in the project root.
if is_placeholder "${REPO_ROOT:-}"; then
  SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd -P)"
  REPO_ROOT="$SCRIPT_DIR"
  info "REPO_ROOT not set — assuming script directory: $REPO_ROOT"
fi

if is_placeholder "$DEVELOPMENT_TEAM"; then
  ios_ini="$REPO_ROOT/Config/DefaultEngine.ini"
  team="$(read_ini_value "$ios_ini" "IOSTeamID")"
  if [[ -n "$team" ]]; then
    DEVELOPMENT_TEAM="$team"
    info "Detected DEVELOPMENT_TEAM from INI (IOSTeamID): $DEVELOPMENT_TEAM"
  fi
fi

# Normalize UPROJECT_PATH if provided via env var (CLI path is already resolved above).
if [[ -n "${UPROJECT_PATH:-}" ]]; then
  if [[ "$UPROJECT_PATH" != /* ]]; then
    if [[ -n "${REPO_ROOT:-}" ]]; then
      UPROJECT_PATH="$(abspath_from "$REPO_ROOT" "$UPROJECT_PATH")"
    else
      UPROJECT_PATH="$(abspath_from "$(/bin/pwd -P)" "$UPROJECT_PATH")"
    fi
  fi
  if [[ -f "$UPROJECT_PATH" ]]; then
    UPROJECT_NAME="$(/usr/bin/basename "$UPROJECT_PATH")"
    if is_placeholder "${REPO_ROOT:-}"; then
      REPO_ROOT="$(/usr/bin/dirname "$UPROJECT_PATH")"
    fi
  fi
fi

if [[ -n "${XCODE_WORKSPACE:-}" && "$XCODE_WORKSPACE" == /* ]]; then
  WORKSPACE="$XCODE_WORKSPACE"
  XCODE_WORKSPACE="$(/usr/bin/basename "$WORKSPACE")"
fi

# Auto-detect UE_ROOT (macOS EGL installs) if not provided.
autodetect_ue_root_if_needed
# Normalize REPO_ROOT to an absolute path (best-effort).
# IMPORTANT: resolve relative paths (including ".") against the CURRENT working directory,
# not against "/".
if [[ -n "${REPO_ROOT:-}" && "$REPO_ROOT" != /* ]]; then
  REPO_ROOT="$(abspath_from "$(/bin/pwd -P)" "$REPO_ROOT")"
fi

# Auto-detect the .uproject, names, and common workspace naming convention when placeholders are used.
autodetect_uproject_if_needed

# Construct UPROJECT_PATH if it wasn't provided, then normalize it to an absolute path.
UPROJECT_PATH="${UPROJECT_PATH:-$REPO_ROOT/$UPROJECT_NAME}"
if [[ -f "$UPROJECT_PATH" ]]; then
  UPROJECT_PATH="$(abspath_existing "$UPROJECT_PATH")"
fi

# Ensure REPO_ROOT matches the actual uproject directory once we have the uproject path.
if [[ -n "${UPROJECT_PATH:-}" && -f "$UPROJECT_PATH" ]]; then
  REPO_ROOT="$(/usr/bin/dirname "$UPROJECT_PATH")"
fi

autodetect_names_if_needed

# Try the common "<Project> (Mac).xcworkspace" guess before the more general workspace find.
# Full workspace detection (including iOS) is deferred to after GenerateProjectFiles runs.
autodetect_workspace_guess_if_needed
autodetect_export_plist_if_needed
autodetect_ios_export_plist_if_needed
autodetect_mas_export_plist_if_needed
autodetect_asc_credentials_if_needed
autodetect_steam_if_needed
autodetect_steam_dylib_src_from_engine_if_needed

# Derive common paths (after CLI parsing/autodetect).
# WORKSPACE/SCHEME are deferred: full detection runs after GenerateProjectFiles.
# Only construct WORKSPACE now if XCODE_WORKSPACE is already resolved (CLI,
# env, or the early convention guess) — avoid a garbage "$REPO_ROOT/" path.
UPROJECT_PATH="${UPROJECT_PATH:-$REPO_ROOT/$UPROJECT_NAME}"
if ! is_placeholder "${XCODE_WORKSPACE:-}"; then
  WORKSPACE="${WORKSPACE:-$REPO_ROOT/$XCODE_WORKSPACE}"
fi
SCHEME="${XCODE_SCHEME:-}"

SCRIPTS="$UE_ROOT/$UAT_SCRIPTS_SUBPATH"
UE_EDITOR="$UE_ROOT/$UE_EDITOR_SUBPATH"

# Artifact roots
BUILD_DIR="$REPO_ROOT/$BUILD_DIR_REL"
LOG_DIR="$REPO_ROOT/$LOG_DIR_REL"

# UAT BuildCookRun's -archivedirectory has /<TargetPlatform>/ appended by UAT,
# so we point it at the parent of BUILD_DIR. With the default
# (Saved/Packages/Mac), UAT writes to Saved/Packages/Mac/<App>-Mac-Shipping.app/
# — the same directory that holds the rest of the script's artifacts.
UAT_ARCHIVE_DIR="$(/usr/bin/dirname "$BUILD_DIR")"

# Normalize a few important paths to absolute paths when possible.
# (This helps when the user passes relative paths via env/CLI.)
if [[ -d "${WORKSPACE:-}" ]]; then
  WORKSPACE="$(abspath_existing "$WORKSPACE")"
fi
if [[ -f "$EXPORT_PLIST" ]]; then
  _abs="$(abspath_existing "$EXPORT_PLIST")"
  [[ -n "${_abs:-}" ]] && EXPORT_PLIST="$_abs"
fi
if [[ "$ENABLE_STEAM" == "1" && -f "$STEAM_DYLIB_SRC" ]]; then
  _abs="$(abspath_existing "$STEAM_DYLIB_SRC")"
  [[ -n "${_abs:-}" ]] && STEAM_DYLIB_SRC="$_abs"
fi
unset _abs

#
# Validate required config early (fail fast with helpful messages)
require_not_placeholder "REPO_ROOT" "$REPO_ROOT" "Example: /Users/you/Documents/Unreal Projects/MyGame"
# At this point, autodetection should have filled these unless the repo is unusual.
require_not_placeholder "UPROJECT_NAME" "$UPROJECT_NAME" "Example: MyGame.uproject"
require_not_placeholder "UPROJECT_PATH" "$UPROJECT_PATH" "Example: /path/to/MyGame.uproject"
require_not_placeholder "UE_ROOT" "$UE_ROOT" "Example: /Users/Shared/Epic Games/UE_5.7"
require_not_placeholder "DEVELOPMENT_TEAM" "$DEVELOPMENT_TEAM" "Example: ABCDE12345"
# SIGN_IDENTITY is required only for the Developer ID channel — that's the
# only path that signs per-component with codesign --sign. App Store
# (Mac + iOS) uses xcodebuild + automatic provisioning, which selects the
# identity via the team ID.
if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  require_not_placeholder "SIGN_IDENTITY" "$SIGN_IDENTITY" "Example: Developer ID Application: Your Company (ABCDE12345)"
fi
require_not_placeholder "SHORT_NAME" "$SHORT_NAME" "Example: MG"
require_not_placeholder "LONG_NAME" "$LONG_NAME" "Example: MyGame"

# Xcode inputs are only required if you use the Xcode archive/export steps.
# Each Mac channel has its own ExportOptions.plist (different `method` values —
# Apple rejects the wrong one at export). Workspace + scheme detection and
# validation are deferred to after GenerateProjectFiles runs (see post-regen
# block below).
if [[ "$USE_XCODE_EXPORT" == "1" && "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  require_not_placeholder "EXPORT_PLIST" "$EXPORT_PLIST" "Point at an ExportOptions.plist compatible with Developer ID exports"
fi
if [[ "$USE_XCODE_EXPORT" == "1" && "$MAC_DISTRIBUTION" == "app-store" && "${PRINT_CONFIG:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
  require_not_placeholder "MAS_EXPORT_PLIST" "${MAS_EXPORT_PLIST:-}" "Copy MAS-ExportOptions.plist.example to MAS-ExportOptions.plist and edit"
fi

# iOS export plist validated early (doesn't depend on workspace generation).
if [[ "${ENABLE_IOS:-0}" == "1" && "${PRINT_CONFIG:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
  require_not_placeholder "IOS_EXPORT_PLIST" "${IOS_EXPORT_PLIST:-}" "Copy iOS-ExportOptions.plist.example to iOS-ExportOptions.plist and edit"
fi


# Optional Steam validation (only when enabled)
if [[ "$ENABLE_STEAM" == "1" ]]; then
  if is_placeholder "$STEAM_DYLIB_SRC"; then
    die "ENABLE_STEAM=1 but STEAM_DYLIB_SRC is not set. The script tried to infer it from UE_ROOT but couldn't. Provide it via --steam-dylib-src (or env/USER CONFIG), or set ENABLE_STEAM=0."
  fi
fi

# VERSION_MODE validation
case "$VERSION_MODE" in
  NONE|MANUAL|DATETIME|HYBRID) ;;
  *) die "VERSION_MODE must be NONE, MANUAL, DATETIME, or HYBRID (got: $VERSION_MODE)" ;;
esac
if [[ "$VERSION_MODE" == "MANUAL" || "$VERSION_MODE" == "HYBRID" ]] && is_placeholder "${VERSION_STRING:-}"; then
  die "VERSION_MODE=$VERSION_MODE but VERSION_STRING is not set. Provide it via --version-string or VERSION_STRING in .env."
fi

# Ask up-front (unless provided via env/CLI)
if [[ -n "${BUILD_TYPE:-}" ]]; then
  # bash 3.2 compatibility: lowercase via tr
  _bto_lower="$(echo "$BUILD_TYPE" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$_bto_lower" in
    shipping|s)    BUILD_TYPE="s" ;;
    development|d) BUILD_TYPE="d" ;;
    *) die "BUILD_TYPE must be 'shipping' or 'development' (or s/d)" ;;
  esac
  unset _bto_lower
else
  read -r -p "Build type? (s=shipping, d=development) [s]: " BUILD_TYPE
  BUILD_TYPE=${BUILD_TYPE:-s}
fi

if [[ "$BUILD_TYPE" =~ ^[Dd]$ ]]; then
  UE_CLIENT_CONFIG="Development"
  XCODE_CONFIG="Development"
  info "Build type: DEVELOPMENT"
else
  UE_CLIENT_CONFIG="Shipping"
  XCODE_CONFIG="Shipping"
  info "Build type: SHIPPING"
fi

if [[ -n "${NOTARIZE:-}" ]]; then
  # bash 3.2 compatibility: lowercase via tr
  _no_lower="$(echo "$NOTARIZE" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$_no_lower" in
    yes) NOTARIZE_ENABLED=1; NOTARIZE="yes" ;;
    no)  NOTARIZE_ENABLED=0; NOTARIZE="no" ;;
    *) die "NOTARIZE must be 'yes' or 'no'" ;;
  esac
  unset _no_lower
elif [[ "$MAC_DISTRIBUTION" != "developer-id" ]]; then
  # Notarization is only meaningful for the Developer ID channel — the Mac
  # App Store + iOS paths gate on App Store review, not notarytool. Default
  # off and skip the prompt to keep MAS runs non-interactive.
  NOTARIZE_ENABLED=0
  NOTARIZE="no"
else
  read -r -p "Notarize + staple this build? (Y/n) " NOTARIZE_ANSWER
  if [[ "${NOTARIZE_ANSWER:-Y}" =~ ^[Nn]$ ]]; then
    NOTARIZE_ENABLED=0
    NOTARIZE="no"
  else
    NOTARIZE_ENABLED=1
    NOTARIZE="yes"
  fi
fi

# If notarization was requested but NOTARY_PROFILE isn't configured, auto-skip with guidance.
if [[ "$NOTARIZE_ENABLED" -eq 1 ]] && is_placeholder "$NOTARY_PROFILE"; then
  warn "Notarization requested, but NOTARY_PROFILE is not configured."
  warn "Skipping notarization + stapling for this run."
  warn "To enable notarization, create a keychain profile and provide it via one of:"
  warn "  - .env / environment variable: NOTARY_PROFILE=\"MyNotaryProfile\""
  warn "  - CLI flag: --notary-profile \"MyNotaryProfile\""
  warn "Create the profile once with:" 
  warn "  xcrun notarytool store-credentials \"MyNotaryProfile\" --apple-id \"you@example.com\" --team-id \"$DEVELOPMENT_TEAM\" --password \"app-specific-password\""
  NOTARIZE_ENABLED=0
fi

# Packaging defaults (only if enabled)
if is_placeholder "$ENABLE_ZIP"; then
  if [[ "$NOTARIZE_ENABLED" -eq 1 ]]; then
    ENABLE_ZIP="1"
  else
    ENABLE_ZIP="0"
  fi
fi

if [[ "$NOTARIZE_ENABLED" -eq 1 && "$ENABLE_ZIP" == "0" && "$ENABLE_DMG" == "0" ]]; then
  die "NOTARIZE=yes but ENABLE_ZIP=0 and ENABLE_DMG=0 — nothing to notarize."
fi

if [[ "$ENABLE_DMG" == "1" ]]; then
  if is_placeholder "$DMG_OUTPUT_DIR"; then
    DMG_OUTPUT_DIR="$BUILD_DIR"
  elif [[ "$DMG_OUTPUT_DIR" != /* ]]; then
    DMG_OUTPUT_DIR="$(abspath_from "$REPO_ROOT" "$DMG_OUTPUT_DIR")"
  fi
  if is_placeholder "$DMG_VOLUME_NAME"; then
    DMG_VOLUME_NAME="$LONG_NAME"
  fi
  if is_placeholder "$DMG_NAME"; then
    DMG_NAME="${LONG_NAME}.dmg"
  fi
fi

# Print resolved config and/or exit early if requested.
if [[ "$PRINT_CONFIG" == "1" ]]; then
  print_config
  exit 0
fi

# Logging — defaults to Saved/Logs (UE's conventional location for derived artifacts).
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build_$(date +%Y-%m-%d_%H-%M-%S).log"
exec >>"$LOG_FILE" 2>&1
echo "Log file: $LOG_FILE" >&3

trap on_error_exit ERR
trap 'restore_content_version_file' EXIT

# Build outputs (Mac, Developer ID)
ARCHIVE_PATH="$BUILD_DIR/${SHORT_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/${SHORT_NAME}-export"
ZIP_PATH="$BUILD_DIR/${LONG_NAME}.zip"

# Build outputs (Mac, App Store) — separate paths so alternating channels
# don't overwrite each other's artifacts.
MAS_ARCHIVE_PATH="$BUILD_DIR/${SHORT_NAME}-mas.xcarchive"
MAS_EXPORT_DIR="$BUILD_DIR/${SHORT_NAME}-mas-export"

# Build outputs (iOS) — parallel of Mac, but under Saved/Packages/IOS/.
# UAT writes to UAT_ARCHIVE_DIR/<TargetPlatform>/, which for iOS is
# Saved/Packages/IOS/. Script-side artifacts (xcarchive, export dir, .ipa)
# live alongside.
IOS_BUILD_DIR="$REPO_ROOT/Saved/Packages/IOS"
IOS_ARCHIVE_PATH="$IOS_BUILD_DIR/${SHORT_NAME}-iOS.xcarchive"
IOS_EXPORT_DIR="$IOS_BUILD_DIR/${SHORT_NAME}-iOS-export"

# NOTE: ZIP_PATH name is cosmetic (uses LONG_NAME). Change LONG_NAME to match your game.
### ===================================

info "Sanity checks"

# Best-effort: warn if the installed Xcode version looks outside this UE install's Apple toolchain policy.
# (Apple_SDK.json is a UE file; it primarily constrains Xcode versions.)
if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  info "Checking Xcode compatibility against Unreal Engine Apple_SDK.json"
  check_apple_sdk_json_compat || true
fi

# Basic file existence checks
[[ -d "$REPO_ROOT" ]] || die "REPO_ROOT does not exist: $REPO_ROOT"
[[ -f "$UPROJECT_PATH" ]] || die "UPROJECT not found: $UPROJECT_PATH"
[[ -d "$SCRIPTS" ]] || die "UAT scripts folder not found: $SCRIPTS"
[[ -x "$SCRIPTS/RunUAT.sh" ]] || die "RunUAT.sh not executable or missing: $SCRIPTS/RunUAT.sh"
[[ -x "$UE_EDITOR" ]] || die "UnrealEditor not found/executable: $UE_EDITOR"

# Tools used later
command -v codesign  >/dev/null 2>&1 || die "codesign not found (unexpected on macOS)."

# Verify the Mac signing identity exists in the keychain before the multi-hour
# build. A typo or expired cert will fail here rather than after UAT finishes
# cooking.
#   - developer-id: explicit Developer ID Application identity (SIGN_IDENTITY)
#     is required because we sign per-component with codesign --sign.
#   - app-store: xcodebuild + automatic provisioning picks the identity, so
#     we don't pin SIGN_IDENTITY — but we still verify an "Apple Distribution"
#     (preferred) or "3rd Party Mac Developer Application" (legacy) identity
#     is present, otherwise xcodebuild archive will fail mid-build.
#   - off (IOS_ONLY): no Mac identity needed.
if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -qF "$SIGN_IDENTITY"; then
    echo "Available Developer ID codesigning identities:" >&3
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep "Developer ID" >&3 || echo "  (none found)" >&3
    die "SIGN_IDENTITY not found in keychain: $SIGN_IDENTITY"
  fi
  good "Signing identity found in keychain."
elif [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
  if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -qE "(Apple Distribution|3rd Party Mac Developer Application)"; then
    echo "Available codesigning identities:" >&3
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null >&3 || echo "  (none found)" >&3
    die "No Mac App Store signing identity in keychain. MAC_DISTRIBUTION=app-store requires either 'Apple Distribution' (preferred) or '3rd Party Mac Developer Application' (legacy). Create one via Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com → Certificates."
  fi
  good "Mac App Store signing identity found in keychain (Apple Distribution / 3rd Party Mac Developer Application)."
fi

# Xcode steps are optional
if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode and the Command Line Tools."
fi
# Workspace existence is checked after GenerateProjectFiles runs (post-regen block).

# Notarization requires Apple tools and a configured, accessible notary profile
if [[ "$NOTARIZE_ENABLED" -eq 1 ]]; then
  command -v xcrun >/dev/null 2>&1 || die "xcrun not found. Install Xcode Command Line Tools."
  if is_placeholder "$NOTARY_PROFILE"; then
    die "Internal error: NOTARIZE_ENABLED=1 but NOTARY_PROFILE is not configured (should have been auto-disabled earlier)."
  fi
  # Verify the notary profile is reachable now, not hours later after the build.
  info "Verifying notary profile accessibility before build"
  if ! wait_for_notary_profile_with_backoff; then
    die "Notary profile '$NOTARY_PROFILE' is not accessible. Verify with: xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""
  fi
  good "Notary profile '$NOTARY_PROFILE' is accessible."
fi

# Mac Developer ID ExportOptions.plist must exist.
if [[ "$USE_XCODE_EXPORT" == "1" && "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  [[ -f "$EXPORT_PLIST" ]] || die "ExportOptions.plist not found: $EXPORT_PLIST"
fi

# Mac App Store ExportOptions.plist must exist + sanity-check its contents.
# Apple rejects mismatched method/teamID at export time, so validating now
# turns a multi-hour wasted build into a one-line error.
if [[ "$USE_XCODE_EXPORT" == "1" && "$MAC_DISTRIBUTION" == "app-store" && "${PRINT_CONFIG:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
  [[ -f "${MAS_EXPORT_PLIST:-}" ]] || die "MAS-ExportOptions.plist not found: ${MAS_EXPORT_PLIST:-<unset>}"
  _mas_plist_flat="$(/bin/cat "$MAS_EXPORT_PLIST" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  if ! echo "$_mas_plist_flat" | /usr/bin/grep -qE '<key>method</key><string>app-store-connect</string>'; then
    die "MAS-ExportOptions.plist ($MAS_EXPORT_PLIST) missing <key>method</key><string>app-store-connect</string>. Mac App Store exports require method=app-store-connect."
  fi
  if ! echo "$_mas_plist_flat" | /usr/bin/grep -qE '<key>signingStyle</key><string>automatic</string>'; then
    die "MAS-ExportOptions.plist ($MAS_EXPORT_PLIST) missing <key>signingStyle</key><string>automatic</string>. Mac App Store path uses automatic provisioning (-allowProvisioningUpdates)."
  fi
  if ! echo "$_mas_plist_flat" | /usr/bin/grep -qE "<key>teamID</key><string>${DEVELOPMENT_TEAM}</string>"; then
    die "MAS-ExportOptions.plist ($MAS_EXPORT_PLIST) teamID does not match DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM. Update the plist's <key>teamID</key><string>...</string> to '$DEVELOPMENT_TEAM'."
  fi
  unset _mas_plist_flat
  good "MAS-ExportOptions.plist validates: method=app-store-connect, signingStyle=automatic, teamID=$DEVELOPMENT_TEAM."
fi

# iOS ExportOptions.plist must exist if we're exporting iOS.
if [[ "${ENABLE_IOS:-0}" == "1" && "${PRINT_CONFIG:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
  [[ -f "${IOS_EXPORT_PLIST:-}" ]] || die "iOS-ExportOptions.plist not found: ${IOS_EXPORT_PLIST:-<unset>}"
fi

# ASC creds: validate up-front so a typo in the API key path doesn't fail
# after a multi-minute Mac build + iOS archive + IPA export. Used by both
# iOS (--ios-validate-ipa/--ios-upload-ipa) and Mac App Store
# (--mas-validate-app/--mas-upload-app) — same API key, same .p8 file.
if [[ "${PRINT_CONFIG:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
  _need_asc=0
  [[ "${ENABLE_IOS:-0}" == "1" ]] && [[ "${IOS_ASC_VALIDATE:-0}" == "1" || "${IOS_ASC_UPLOAD:-0}" == "1" ]] && _need_asc=1
  [[ "$MAC_DISTRIBUTION" == "app-store" ]] && [[ "${MAS_ASC_VALIDATE:-0}" == "1" || "${MAS_ASC_UPLOAD:-0}" == "1" ]] && _need_asc=1
  if [[ "$_need_asc" -eq 1 ]]; then
    require_not_placeholder "ASC_API_KEY_ID"   "${ASC_API_KEY_ID:-}"   "10-char ASC API key ID; get from appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API"
    require_not_placeholder "ASC_API_ISSUER"   "${ASC_API_ISSUER:-}"   "ASC API issuer UUID (same page as the key ID)"
    require_not_placeholder "ASC_API_KEY_PATH" "${ASC_API_KEY_PATH:-}" "Path to the .p8 file you downloaded from ASC"
    [[ -f "$ASC_API_KEY_PATH" ]] || die "ASC API key file not found: $ASC_API_KEY_PATH"
    good "ASC API credentials accessible."
  fi
  unset _need_asc
fi

if [[ "$ENABLE_DMG" == "1" ]]; then
  command -v hdiutil >/dev/null 2>&1 || die "hdiutil not found (required to create DMG)."
  if [[ "$FANCY_DMG" == "1" ]] && ! command -v osascript >/dev/null 2>&1; then
    warn "FANCY_DMG=1 but osascript is unavailable. DMG will be created without Finder layout tweaks."
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  print_config
  echo "== DRY RUN ==" >&3
  steps=""
  if [[ "$VERSION_MODE" != "NONE" ]]; then
    steps="stamp Content/$VERSION_CONTENT_DIR/version.txt"
  fi
  if [[ -n "$steps" ]]; then steps="$steps → seed canonical UE files"; else steps="seed canonical UE files"; fi
  if [[ "$USE_XCODE_EXPORT" == "1" && "$REGEN_PROJECT_FILES" == "1" ]]; then
    steps="$steps → GenerateProjectFiles"
  fi
  if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then
    steps="$steps → UAT BuildCookRun (Mac)"
    if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
      steps="$steps → Mac Xcode archive/export"
    else
      steps="$steps → (skip Mac Xcode archive/export)"
    fi
    steps="$steps → Mac codesign"
    if [[ "$ENABLE_ZIP" == "1" ]]; then
      steps="$steps → Mac zip"
    fi
    if [[ "$ENABLE_DMG" == "1" ]]; then
      steps="$steps → Mac DMG create+sign"
      if [[ "$FANCY_DMG" == "1" ]]; then
        steps="$steps → DMG Finder layout (experimental)"
      fi
    fi
    if [[ "$NOTARIZE_ENABLED" -eq 1 ]]; then
      steps="$steps → Mac notarize+staple"
    fi
  elif [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
    steps="$steps → UAT BuildCookRun (Mac) → MAS archive/export (automatic provisioning)"
    if [[ "${MAS_ASC_VALIDATE:-0}" == "1" ]]; then
      steps="$steps → MAS ASC validate (-t macos)"
    fi
    if [[ "${MAS_ASC_UPLOAD:-0}" == "1" ]]; then
      steps="$steps → MAS ASC upload (-t macos)"
    fi
  fi
  if [[ "${ENABLE_IOS:-0}" == "1" ]]; then
    steps="$steps → UAT BuildCookRun (iOS) → iOS archive/export → IPA"
    if [[ "${IOS_ASC_VALIDATE:-0}" == "1" ]]; then
      steps="$steps → iOS ASC validate (-t ios)"
    fi
    if [[ "${IOS_ASC_UPLOAD:-0}" == "1" ]]; then
      steps="$steps → iOS ASC upload (-t ios)"
    fi
  fi
  if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
    [[ "$MAC_DISTRIBUTION" != "off" ]] && echo "Would wipe Mac build dir: $BUILD_DIR" >&3
    [[ "${ENABLE_IOS:-0}" == "1" ]] && echo "Would wipe iOS build dir: $IOS_BUILD_DIR" >&3
  fi
  echo "Would run: $steps" >&3
  exit 0
fi

# Resolve the CFBundleVersion that this build will ship. Mutates CFBUNDLE_VERSION
# (auto-bump or explicit-set) and sets _CFBV_PERSIST. Done after the dry-run /
# print-config exits so those modes don't accidentally consume a build number.
_resolve_cfbundle_version_for_build

echo "== Prep output locations ==" >&3
if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$ZIP_PATH"
  if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
    warn "CLEAN_BUILD_DIR=1 — wiping entire build dir: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
  fi
  mkdir -p "$BUILD_DIR"
elif [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
  rm -rf "$MAS_ARCHIVE_PATH" "$MAS_EXPORT_DIR"
  if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
    warn "CLEAN_BUILD_DIR=1 — wiping entire build dir: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
  fi
  mkdir -p "$BUILD_DIR"
fi
if [[ "${ENABLE_IOS:-0}" == "1" ]]; then
  rm -rf "$IOS_ARCHIVE_PATH" "$IOS_EXPORT_DIR"
  if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
    warn "CLEAN_BUILD_DIR=1 — wiping entire iOS build dir: $IOS_BUILD_DIR"
    rm -rf "$IOS_BUILD_DIR"
  fi
  mkdir -p "$IOS_BUILD_DIR"
fi

ensure_game_ini_staging_entry
write_version_to_content
seed_apple_launchscreen_compat
seed_mac_info_template_plist
seed_mac_update_version_after_build_script
seed_mac_package_version_counter
ensure_macos_canonical_appicon
ensure_ios_canonical_appicon
ensure_app_category_in_engine_ini
ensure_marketing_version_in_engine_ini
ensure_mac_app_store_entitlements
ensure_game_center_entitlements
regenerate_project_files

# ---------------------------------------------------------------------------
# Post-regen workspace + scheme resolution
# GenerateProjectFiles has now run (when REGEN_PROJECT_FILES=1), so workspaces
# that didn't exist before the regen are on disk. Detect them here rather than
# up-front so a first-time run never needs to prompt or pre-generate manually.
# ---------------------------------------------------------------------------
if [[ "$USE_XCODE_EXPORT" == "1" && "${IOS_ONLY:-0}" != "1" ]]; then
  autodetect_workspace_if_needed
  autodetect_scheme_if_needed
  if ! is_placeholder "${XCODE_WORKSPACE:-}"; then
    WORKSPACE="${WORKSPACE:-$REPO_ROOT/$XCODE_WORKSPACE}"
  fi
  if [[ -d "${WORKSPACE:-}" ]]; then
    WORKSPACE="$(abspath_existing "$WORKSPACE")"
  fi
  SCHEME="$XCODE_SCHEME"
  require_not_placeholder "XCODE_WORKSPACE" "$XCODE_WORKSPACE" "Example: YourProject (Mac).xcworkspace"
  require_not_placeholder "XCODE_SCHEME" "$XCODE_SCHEME" "Example: YourProject"
  [[ -d "$WORKSPACE" ]] || die "Xcode workspace not found after project file generation (expected a .xcworkspace directory): $WORKSPACE"
fi

if [[ "${ENABLE_IOS:-0}" == "1" && "${PRINT_CONFIG:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
  autodetect_ios_workspace_if_needed
  autodetect_ios_scheme_if_needed
  require_not_placeholder "IOS_WORKSPACE" "${IOS_WORKSPACE:-}" "Example: YourProject (iOS).xcworkspace"
  require_not_placeholder "IOS_SCHEME" "${IOS_SCHEME:-}" "Example: YourProject"
fi

if [[ "${IOS_ONLY:-0}" != "1" ]]; then
  info "Building game (UAT BuildCookRun, Mac)"

  "$SCRIPTS/RunUAT.sh" BuildCookRun \
    -unrealexe="$UE_EDITOR" \
    -project="$UPROJECT_PATH" \
    -noP4 -build -cook -pak -iostore \
    -targetplatform=Mac -clientconfig="$UE_CLIENT_CONFIG" \
    -stage -package \
    -archive -archivedirectory="$UAT_ARCHIVE_DIR" \
    -utf8output -verbose -specifiedarchitecture=arm64+x86_64

  echo "== Note: UE clientconfig=$UE_CLIENT_CONFIG, Xcode configuration=$XCODE_CONFIG ==" >&3
fi

# Mac post-UAT pipeline. Two channels, picked by MAC_DISTRIBUTION:
#
#   developer-id : Xcode archive (manual entitlements) → per-component
#                  codesign → optional ZIP/DMG → optional notarize + staple.
#                  This is the direct-download path (most of ship.sh's
#                  existing logic).
#
#   app-store    : Xcode archive (automatic provisioning,
#                  -allowProvisioningUpdates) → exportArchive against
#                  MAS-ExportOptions.plist → optional xcrun altool -t macos
#                  validate/upload. No codesign loop, no notarize/staple,
#                  no ZIP/DMG. ASC review is the equivalent gate.
#
# Skipped entirely when MAC_DISTRIBUTION=off (IOS_ONLY runs).
if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then

if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  # CFBundleVersion build-setting override. Apple-documented: command-line
  # build settings take precedence over xcconfig, so passing CURRENT_PROJECT_VERSION
  # here shadows UE's xcconfig "CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION)".
  # Xcode bakes our value into the .app's Info.plist at archive time AND into
  # the .xcarchive's top-level Info.plist (what Organizer reads), all in one
  # pass — no PlistBuddy fixups needed afterwards. No-op on Path A (resolver
  # leaves CFBUNDLE_VERSION empty when USE_UE_PACKAGE_VERSION_COUNTER=1).
  _xcb_settings=()
  [[ -n "${CFBUNDLE_VERSION:-}" ]] && _xcb_settings+=("CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION")

  echo "== Archive (NO CLEAN) with Automatic signing ==" >&3
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$XCODE_CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    "${_xcb_settings[@]}"

  echo "== Export signed app for Developer ID ==" >&3
  # ExportOptions.plist controls how Xcode exports the archive.
  # This script expects you to provide one (and can auto-detect a suitable plist in repo root).
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"
else
  info "USE_XCODE_EXPORT=0 — skipping Xcode archive/export"
fi

# Locate the .app bundle.
# - If using Xcode export, it should be in EXPORT_DIR.
# - If skipping Xcode, it should be somewhere under BUILD_DIR (UAT output layout varies).
if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  APP_PATH="$(find_first_app_under "$EXPORT_DIR")"
  if [[ -z "${APP_PATH:-}" ]]; then
    /bin/ls -la "$EXPORT_DIR" >&3 || true
    die "No .app found under export dir: $EXPORT_DIR"
  fi
else
  APP_PATH="$(find_first_app_under "$BUILD_DIR")"
  if [[ -z "${APP_PATH:-}" ]]; then
    /bin/ls -la "$BUILD_DIR" >&3 || true
    die "No .app found under build dir: $BUILD_DIR — UAT output layouts differ by project/settings. Try enabling Xcode export (USE_XCODE_EXPORT=1) or point the script at the correct output."
  fi
fi

if [[ "$ENABLE_STEAM" == "1" ]]; then
  echo "WRITE_STEAM_APPID: $WRITE_STEAM_APPID" >&3
fi
echo "App: $APP_PATH" >&3

if [[ "$ENABLE_STEAM" == "1" ]]; then
  STEAM_APPID_PATH="$APP_PATH/Contents/MacOS/steam_appid.txt"
  if [[ "${WRITE_STEAM_APPID:-0}" == "1" ]]; then
    echo "== Write steam_appid.txt for local (non-Steam-client) launches (WRITE_STEAM_APPID=1) ==" >&3
    echo "$STEAM_APP_ID" > "$STEAM_APPID_PATH"
    chmod 644 "$STEAM_APPID_PATH"
  else
    # When launching from the Steam client, Steam provides the AppID and a steam_appid.txt can cause confusing test behavior.
    if [[ -f "$STEAM_APPID_PATH" ]]; then
      echo "== Removing steam_appid.txt (Steam client launch should not need it) ==" >&3
      rm -f "$STEAM_APPID_PATH"
    else
      echo "== Not writing steam_appid.txt (Steam client launch should not need it) ==" >&3
    fi
  fi
else
  info "Steam disabled (ENABLE_STEAM=0) — skipping steam_appid.txt"
fi

if [[ "$ENABLE_STEAM" == "1" ]]; then
  info "Ensure Steam dylib is next to the executable (macOS)"

  STEAM_DYLIB_DEST="$APP_PATH/Contents/MacOS/libsteam_api.dylib"

  if [[ ! -f "$STEAM_DYLIB_SRC" ]]; then
    die "Steam dylib source not found: $STEAM_DYLIB_SRC"
  fi

  cp -fv "$STEAM_DYLIB_SRC" "$STEAM_DYLIB_DEST"

  echo "Signing Steam dylib: $STEAM_DYLIB_DEST" >&3
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STEAM_DYLIB_DEST"
else
  info "Steam disabled (ENABLE_STEAM=0) — skipping libsteam_api.dylib staging"
fi

TMP_PREFIX="$(sanitize_name_for_tmp "$SHORT_NAME")"
# Entitlements: hardened runtime is required for Developer ID signing.
# Steam overlay / Steam client libraries may require disabling library validation.
# Only enable those entitlements when you actually need them.
#
# If ENTITLEMENTS_FILE is already set (e.g. user-provided via env or future CLI flag),
# use it as-is and do not generate or clean it up. Otherwise, generate a temp file.
if is_placeholder "${ENTITLEMENTS_FILE:-}"; then
  # macOS mktemp requires XXXXXX at the very end of the template; any suffix
  # after them (e.g. ".plist") prevents substitution and creates a file with
  # the literal name "…XXXXXX.plist". Drop the extension — codesign reads the
  # file by path and does not care about the filename extension.
  _ENTITLEMENTS_TMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}${TMP_PREFIX}_entitlements_XXXXXX")"
  ENTITLEMENTS_FILE="$_ENTITLEMENTS_TMP"
else
  _ENTITLEMENTS_TMP=""
  info "Using user-provided ENTITLEMENTS_FILE: $ENTITLEMENTS_FILE"
fi

if [[ -n "$_ENTITLEMENTS_TMP" ]]; then
  # Script-generated entitlements: write the appropriate content.
  if [[ "$ENABLE_STEAM" == "1" ]]; then
    cat > "$ENTITLEMENTS_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key>
  <true/>
</dict>
</plist>
PLIST
  else
    # Minimal entitlements file. Keeping it empty is valid for many apps.
    cat > "$ENTITLEMENTS_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
  fi
fi

echo "Using signing identity: $SIGN_IDENTITY" >&3

# Apple deprecated --deep for distribution signing. The correct approach is to
# sign all nested dylibs and frameworks individually first, then sign the outer
# .app. This ensures each component has a valid, independent signature that
# Gatekeeper and notarization can verify.
echo "== Re-signing app bundle (per-component, then outer) ==" >&3

while IFS= read -r -d '' lib; do
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$lib"
done < <(/usr/bin/find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null)

while IFS= read -r -d '' fwk; do
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$fwk"
done < <(/usr/bin/find "$APP_PATH/Contents" -type d -name "*.framework" -print0 2>/dev/null)

/usr/bin/codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGN_IDENTITY" "$APP_PATH"

echo "== Validations (fail fast) ==" >&3

# Resolve the actual executable name from Info.plist
APP_EXE_NAME=$(/usr/bin/defaults read "$APP_PATH/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)
if [[ -z "${APP_EXE_NAME:-}" ]]; then
  die "Could not read CFBundleExecutable from $APP_PATH/Contents/Info.plist"
fi
EXE_PATH="$APP_PATH/Contents/MacOS/$APP_EXE_NAME"

if [[ ! -f "$EXE_PATH" ]]; then
  die "Expected executable not found: $EXE_PATH"
fi

# NOTE: To verify the build configuration at runtime, launch with -log and look for:
#   LogInit: Build: Shipping
# Scanning binary strings for "Development" is not reliable — UE Shipping builds
# legitimately contain that word in class names, log strings, and linker symbols.

# 1) If Steam is enabled, verify the main exe references Steam as @loader_path
if [[ "$ENABLE_STEAM" == "1" ]]; then
  if ! /usr/bin/otool -L "$EXE_PATH" | /usr/bin/grep -q "@loader_path/libsteam_api.dylib"; then
    /usr/bin/otool -L "$EXE_PATH" | /usr/bin/grep -i steam >&3 || true
    die "Executable does not reference @loader_path/libsteam_api.dylib — Steam dylib was not linked at the expected rpath."
  fi
fi

# 2) Verify signatures strictly (no || true)
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# 2b) Show entitlements (log proof)
echo "-- Entitlements (app) --" >&3
ENT_OUT=$(/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)
echo "$ENT_OUT" >&3

if [[ "$ENABLE_STEAM" == "1" ]]; then
  echo "$ENT_OUT" | /usr/bin/grep -n "disable-library-validation" >&3 || { die "disable-library-validation entitlement not present (required for some Steam client/overlay scenarios)"; }
  echo "$ENT_OUT" | /usr/bin/grep -n "allow-dyld-environment-variables" >&3 || { die "allow-dyld-environment-variables entitlement not present (Steam overlay commonly needs this)"; }
fi

# 3) Show team IDs in log for confidence
/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/grep -E "^(Authority=|TeamIdentifier=)" || true

if [[ "$ENABLE_STEAM" == "1" ]]; then
  /usr/bin/codesign -dv --verbose=4 "$STEAM_DYLIB_DEST" 2>&1 | /usr/bin/grep -E "^(Authority=|TeamIdentifier=)" || true
fi

# Sanity: ensure TeamIdentifier matches for app + dylib
APP_TEAM=$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/awk -F'=' '/^TeamIdentifier=/{print $2; exit}')

if [[ "$ENABLE_STEAM" == "1" ]]; then
  DYLIB_TEAM=$(/usr/bin/codesign -dv --verbose=4 "$STEAM_DYLIB_DEST" 2>&1 | /usr/bin/awk -F'=' '/^TeamIdentifier=/{print $2; exit}')

  echo "TeamIdentifier (app):   ${APP_TEAM:-<none>}" >&3
  echo "TeamIdentifier (dylib): ${DYLIB_TEAM:-<none>}" >&3
  if [[ -n "${APP_TEAM:-}" && -n "${DYLIB_TEAM:-}" && "$APP_TEAM" != "$DYLIB_TEAM" ]]; then
    die "TeamIdentifier mismatch between app ($APP_TEAM) and libsteam_api.dylib ($DYLIB_TEAM) — dyld will refuse to load it."
  fi
else
  echo "TeamIdentifier (app):   ${APP_TEAM:-<none>}" >&3
fi

if [[ "$ENABLE_ZIP" == "1" ]]; then
  echo "== Create ZIP (no extra parent) ==" >&3
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  echo "Zip: $ZIP_PATH" >&3
else
  echo "== Skipping ZIP creation (ENABLE_ZIP=0) ==" >&3
fi

if [[ "$ENABLE_DMG" == "1" ]]; then
  DMG_PATH="$DMG_OUTPUT_DIR/$DMG_NAME"
  echo "== Create DMG ==" >&3
  mkdir -p "$DMG_OUTPUT_DIR"
  rm -f "$DMG_PATH"
  if [[ "$FANCY_DMG" == "1" ]]; then
    warn "FANCY_DMG=1 is experimental and may not persist layout consistently."
    DMG_STAGE_DIR="$(/usr/bin/mktemp -d -t dmgstage.XXXXXX)"
    DMG_RW_PATH="$DMG_OUTPUT_DIR/${DMG_NAME%.dmg}-rw.dmg"
    DMG_MOUNT_DIR="/Volumes/${DMG_VOLUME_NAME}-$$"
    DMG_MOUNT_BASENAME="$(/usr/bin/basename "$DMG_MOUNT_DIR")"
    DMG_MOUNT_BASENAME_ESC="${DMG_MOUNT_BASENAME//\"/\\\"}"
    STAGED_APP_NAME="$(/usr/bin/basename "$APP_PATH")"
    APP_ESC="${STAGED_APP_NAME//\"/\\\"}"

    /usr/bin/ditto "$APP_PATH" "$DMG_STAGE_DIR/$STAGED_APP_NAME"
    /bin/ln -s /Applications "$DMG_STAGE_DIR/Applications"

    /bin/rm -f "$DMG_RW_PATH"
    /usr/bin/hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$DMG_STAGE_DIR" -ov -format UDRW -fs HFS+ "$DMG_RW_PATH"
    /usr/bin/hdiutil attach "$DMG_RW_PATH" -mountpoint "$DMG_MOUNT_DIR" -nobrowse -readwrite
    /bin/sleep 1

    if command -v osascript >/dev/null 2>&1; then
      /usr/bin/osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
      /bin/rm -f "$DMG_MOUNT_DIR/.DS_Store"
      /bin/sleep 2
      /usr/bin/osascript <<OSA || warn "Finder layout scripting failed; continuing with DMG creation."
tell application "Finder"
  set dmFolder to POSIX file "/Volumes/${DMG_MOUNT_BASENAME_ESC}/" as alias
  open dmFolder
  delay 1
  set dmWin to container window of dmFolder
  set current view of dmWin to icon view
  delay 1
  set toolbar visible of dmWin to false
  set statusbar visible of dmWin to false
  set bounds of dmWin to {200, 200, 860, 560}
  set dmViewOptions to icon view options of dmWin
  set arrangement of dmViewOptions to not arranged
  set icon size of dmViewOptions to 144
  delay 1
  set position of item "${APP_ESC}" of dmFolder to {200, 100}
  set position of item "Applications" of dmFolder to {450, 100}
  delay 1
  close dmWin
  open dmFolder
  delay 1
  try
    close container window of dmFolder
  end try
end tell
OSA
      /bin/sleep 2
    fi

    DMG_DS_STORE="$DMG_MOUNT_DIR/.DS_Store"
    DMG_PREV_SIZE=0
    DMG_PREV_MTIME=0
    DMG_STABLE_COUNT=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if [[ -f "$DMG_DS_STORE" ]]; then
        DMG_SIZE="$(/usr/bin/stat -f%z "$DMG_DS_STORE" 2>/dev/null || echo 0)"
        DMG_MTIME="$(/usr/bin/stat -f%m "$DMG_DS_STORE" 2>/dev/null || echo 0)"
        if [[ "$DMG_SIZE" -gt 0 && "$DMG_SIZE" -eq "$DMG_PREV_SIZE" && "$DMG_MTIME" -eq "$DMG_PREV_MTIME" ]]; then
          DMG_STABLE_COUNT=$((DMG_STABLE_COUNT + 1))
        else
          DMG_STABLE_COUNT=0
        fi
        if [[ "$DMG_STABLE_COUNT" -ge 2 ]]; then
          break
        fi
        DMG_PREV_SIZE="$DMG_SIZE"
        DMG_PREV_MTIME="$DMG_MTIME"
      fi
      /bin/sleep 1
    done

    /bin/sync
    /bin/sleep 2
    if command -v osascript >/dev/null 2>&1; then
      /usr/bin/osascript <<OSA >/dev/null 2>&1 || true
tell application "Finder"
  try
    eject (POSIX file "/Volumes/${DMG_MOUNT_BASENAME_ESC}/" as alias)
  end try
end tell
OSA
    fi

    DMG_DETACHED=0
    for i in 1 2 3 4 5; do
      if [[ ! -d "$DMG_MOUNT_DIR" ]]; then
        DMG_DETACHED=1
        break
      fi
      if /usr/bin/hdiutil detach "$DMG_MOUNT_DIR" >/dev/null 2>&1; then
        DMG_DETACHED=1
        break
      fi
      /bin/sleep $((i * 2))
    done
    if [[ "$DMG_DETACHED" -eq 0 && -d "$DMG_MOUNT_DIR" ]]; then
      warn "Forced detach used; DMG layout metadata may not persist."
      /usr/bin/hdiutil detach -force "$DMG_MOUNT_DIR" >/dev/null 2>&1 || true
    fi

    /usr/bin/hdiutil convert "$DMG_RW_PATH" -format UDZO -o "$DMG_PATH"
    /bin/rm -f "$DMG_RW_PATH"
    /bin/rm -rf "$DMG_STAGE_DIR"
  else
    /usr/bin/hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
  fi
  echo "DMG: $DMG_PATH" >&3

  echo "== Sign DMG ==" >&3
  /usr/bin/codesign -s "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  echo "== Verify DMG signature ==" >&3
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
else
  info "ENABLE_DMG=0 — skipping DMG creation"
fi

ZIP_NOTARY_ID=""
DMG_NOTARY_ID=""
SKIP_DMG_NOTARY=0

if [[ "$NOTARIZE_ENABLED" -eq 1 ]]; then
  if [[ "$ENABLE_ZIP" == "1" ]]; then
    echo "== Notarize ZIP (submit) ==" >&3
    ZIP_NOTARY_ID="$(submit_notary "$ZIP_PATH" "ZIP")"
  fi

  if [[ "$ENABLE_DMG" == "1" ]]; then
    if [[ "$ENABLE_ZIP" == "1" ]]; then
      if ! wait_for_notary_profile_with_backoff; then
        warn "Notary profile still not accessible after retries. Skipping DMG notarization."
        warn "You can notarize and staple the DMG manually:"
        warn "  /usr/bin/xcrun notarytool submit \"$DMG_PATH\" --keychain-profile \"$NOTARY_PROFILE\" --wait"
        warn "  /usr/bin/xcrun stapler staple \"$DMG_PATH\""
        warn "  /usr/bin/xcrun stapler validate \"$DMG_PATH\""
        SKIP_DMG_NOTARY=1
      fi
    fi

    if [[ "$SKIP_DMG_NOTARY" -eq 0 ]]; then
      echo "== Notarize DMG (submit) ==" >&3
      DMG_NOTARY_ID="$(submit_notary "$DMG_PATH" "DMG")"
    fi
  fi

  if [[ -n "$ZIP_NOTARY_ID" ]]; then
    wait_notary "$ZIP_NOTARY_ID" "ZIP"
  fi

  if [[ -n "$DMG_NOTARY_ID" ]]; then
    wait_notary "$DMG_NOTARY_ID" "DMG"
    echo "== Staple DMG ==" >&3
    /usr/bin/xcrun stapler staple "$DMG_PATH"
  fi

  # Staple the app after any successful notarization (ZIP or DMG-only).
  # Without this, Gatekeeper blocks the app on a fresh Mac even if notarization
  # succeeded — the ticket must be stapled regardless of which artifact was used.
  if [[ -n "$ZIP_NOTARY_ID" || -n "$DMG_NOTARY_ID" ]]; then
    echo "== Staple app ==" >&3
    /usr/bin/xcrun stapler staple "$APP_PATH"

    echo "== Staple validation (app) ==" >&3
    /usr/bin/xcrun stapler validate "$APP_PATH" || true

    echo "== Gatekeeper assessment (app) ==" >&3
    /usr/sbin/spctl -a -vv "$APP_PATH" || true
  fi
else
  echo "== Notarization disabled (NOTARIZE=no) ==" >&3
fi

fi  # end if [[ "$MAC_DISTRIBUTION" == "developer-id" ]] — Mac Developer ID pipeline

# ---------------------------------------------------------------------------
# Mac App Store pipeline (Xcode archive/export under automatic provisioning,
# optional xcrun altool -t macos validate/upload). Mirrors the iOS pipeline
# below — same tooling, only the -t target differs. No codesign loop, no
# entitlements temp file, no notarize/staple, no ZIP/DMG: ASC review is the
# equivalent gate, and the script-generated entitlements (Steam-style) would
# get an outright reject from MAS review.
# ---------------------------------------------------------------------------
if [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
  # CFBundleVersion override mirrors the Developer ID branch — Apple
  # documented: command-line build settings beat xcconfig.
  _mas_xcb_settings=()
  [[ -n "${CFBUNDLE_VERSION:-}" ]] && _mas_xcb_settings+=("CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION")
  # Always pass CODE_SIGN_ENTITLEMENTS for MAS. The file was seeded by
  # ensure_mac_app_store_entitlements() (sandbox=true, MAS-mandatory) and
  # extended by ensure_game_center_entitlements() when ENABLE_GAME_CENTER=1
  # (adds Game Center + network.client). Without this override, xcodebuild
  # would fall back to UE's xcconfig CODE_SIGN_ENTITLEMENTS path which the
  # MAS-channel-specific keys never reach.
  _mas_xcb_settings+=("CODE_SIGN_ENTITLEMENTS=$(mac_app_store_entitlements_path)")

  echo "== Mac App Store Archive (automatic provisioning) ==" >&3
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$XCODE_CONFIG" \
    -destination 'generic/platform=macOS' \
    -archivePath "$MAS_ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    "${_mas_xcb_settings[@]}"

  echo "== Mac App Store Export (.pkg for App Store Connect) ==" >&3
  # Xcode exports a signed .pkg installer (productbuild output) for the
  # app-store-connect method on macOS — NOT a .app bundle. The .pkg wraps
  # the signed .app and is the artifact altool uploads to ASC.
  xcodebuild -exportArchive \
    -archivePath "$MAS_ARCHIVE_PATH" \
    -exportPath "$MAS_EXPORT_DIR" \
    -exportOptionsPlist "$MAS_EXPORT_PLIST" \
    -allowProvisioningUpdates

  MAS_PKG_PATH="$(/usr/bin/find "$MAS_EXPORT_DIR" -maxdepth 2 -type f -name '*.pkg' -print -quit 2>/dev/null || true)"
  if [[ -z "${MAS_PKG_PATH:-}" ]]; then
    /bin/ls -la "$MAS_EXPORT_DIR" >&3 || true
    die "No .pkg found under MAS export dir: $MAS_EXPORT_DIR. Mac App Store exports produce a signed installer package, not a .app bundle. Verify the MAS-ExportOptions.plist declares method=app-store-connect and that an 'Apple Distribution' or '3rd Party Mac Developer Installer' identity is in the keychain."
  fi
  good "Mac App Store .pkg: $MAS_PKG_PATH"

  # Quick verification — Xcode signed the pkg under automatic provisioning.
  # pkgutil --check-signature confirms the installer signature is valid and
  # surfaces the signing chain before upload, so a malformed pkg fails here
  # instead of mid-altool with a less legible error.
  echo "== Mac App Store installer signature verification ==" >&3
  /usr/sbin/pkgutil --check-signature "$MAS_PKG_PATH" >&3 || die "pkgutil could not verify the .pkg signature: $MAS_PKG_PATH"

  if [[ "${MAS_ASC_VALIDATE:-0}" == "1" ]]; then
    echo "== Mac App Store Validate (App Store Connect) ==" >&3
    /usr/bin/xcrun altool --validate-app \
      -f "$MAS_PKG_PATH" \
      -t macos \
      --apiKey "$ASC_API_KEY_ID" \
      --apiIssuer "$ASC_API_ISSUER" \
      --private-key "$ASC_API_KEY_PATH"
    good "Mac App Store .pkg passed App Store Connect validation."

    # Offer upload interactively when the user opted into validate but
    # hadn't explicitly committed to upload. Flag-driven runs and CI
    # (non-TTY) bypass this — the prompt is opt-in safety, not a gate.
    if [[ "${MAS_ASC_UPLOAD:-0}" != "1" ]] && _maybe_prompt_for_asc_upload "$MAS_PKG_PATH"; then
      MAS_ASC_UPLOAD=1
    fi
  fi

  if [[ "${MAS_ASC_UPLOAD:-0}" == "1" ]]; then
    echo "== Mac App Store Upload (App Store Connect) ==" >&3
    /usr/bin/xcrun altool --upload-app \
      -f "$MAS_PKG_PATH" \
      -t macos \
      --apiKey "$ASC_API_KEY_ID" \
      --apiIssuer "$ASC_API_ISSUER" \
      --private-key "$ASC_API_KEY_PATH"
    good "Mac App Store .pkg uploaded to App Store Connect."
  fi
fi

# ---------------------------------------------------------------------------
# iOS pipeline (UAT → archive → IPA → optional ASC validate/upload)
# ---------------------------------------------------------------------------
# Runs after Mac when ENABLE_IOS=1, or alone when IOS_ONLY=1. Skipped entirely
# when ENABLE_IOS=0. iOS doesn't need our per-component codesign or notarization
# — xcodebuild + ExportOptions.plist handle App Store signing, and the App
# Store equivalent of notarization is the upload itself.
if [[ "${ENABLE_IOS:-0}" == "1" ]]; then
  info "Building game (UAT BuildCookRun, iOS)"

  "$SCRIPTS/RunUAT.sh" BuildCookRun \
    -unrealexe="$UE_EDITOR" \
    -project="$UPROJECT_PATH" \
    -noP4 -build -cook -pak -iostore \
    -targetplatform=IOS -clientconfig="$UE_CLIENT_CONFIG" \
    -stage -package \
    -archive -archivedirectory="$UAT_ARCHIVE_DIR" \
    -utf8output -verbose

  # Same CFBundleVersion build-setting override as Mac. Shared CFBUNDLE_VERSION
  # value across both archives — one bump per ship.sh run, both platforms ship
  # the same number.
  _ios_xcb_settings=()
  [[ -n "${CFBUNDLE_VERSION:-}" ]] && _ios_xcb_settings+=("CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION")
  if [[ "${ENABLE_GAME_CENTER:-}" == "1" ]]; then
    _ios_xcb_settings+=("CODE_SIGN_ENTITLEMENTS=$REPO_ROOT/Build/IOS/Resources/${UPROJECT_NAME%.uproject}.entitlements")
  fi

  echo "== iOS Archive ==" >&3
  xcodebuild \
    -workspace "$IOS_WORKSPACE" \
    -scheme "$IOS_SCHEME" \
    -configuration "$XCODE_CONFIG" \
    -destination 'generic/platform=iOS' \
    -archivePath "$IOS_ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    "${_ios_xcb_settings[@]}"

  echo "== iOS Export (IPA) ==" >&3
  xcodebuild -exportArchive \
    -archivePath "$IOS_ARCHIVE_PATH" \
    -exportPath "$IOS_EXPORT_DIR" \
    -exportOptionsPlist "$IOS_EXPORT_PLIST" \
    -allowProvisioningUpdates

  IOS_IPA_PATH="$(/usr/bin/find "$IOS_EXPORT_DIR" -maxdepth 3 -type f -name '*.ipa' -print -quit 2>/dev/null || true)"
  if [[ -z "${IOS_IPA_PATH:-}" ]]; then
    /bin/ls -la "$IOS_EXPORT_DIR" >&3 || true
    die "No .ipa found under iOS export dir: $IOS_EXPORT_DIR"
  fi
  good "iOS IPA: $IOS_IPA_PATH"

  # ASC creds were validated at pre-flight (see "ASC API credentials accessible.").

  if [[ "${IOS_ASC_VALIDATE:-0}" == "1" ]]; then
    echo "== iOS Validate (App Store Connect) ==" >&3
    /usr/bin/xcrun altool --validate-app \
      -f "$IOS_IPA_PATH" \
      -t ios \
      --apiKey "$ASC_API_KEY_ID" \
      --apiIssuer "$ASC_API_ISSUER" \
      --private-key "$ASC_API_KEY_PATH"
    good "iOS IPA passed App Store Connect validation."

    # Offer upload interactively when the user opted into validate but
    # hadn't explicitly committed to upload. Flag-driven runs and CI
    # (non-TTY) bypass this — symmetric with the MAS path above.
    if [[ "${IOS_ASC_UPLOAD:-0}" != "1" ]] && _maybe_prompt_for_asc_upload "$IOS_IPA_PATH"; then
      IOS_ASC_UPLOAD=1
    fi
  fi

  if [[ "${IOS_ASC_UPLOAD:-0}" == "1" ]]; then
    echo "== iOS Upload (App Store Connect) ==" >&3
    /usr/bin/xcrun altool --upload-app \
      -f "$IOS_IPA_PATH" \
      -t ios \
      --apiKey "$ASC_API_KEY_ID" \
      --apiIssuer "$ASC_API_ISSUER" \
      --private-key "$ASC_API_KEY_PATH"
    good "iOS IPA uploaded to App Store Connect."
  fi
fi

echo "REMINDER: Test your distribution path." >&3
if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  echo "  - If distributing via a launcher (Steam, Epic, etc.), test launching from that launcher." >&3
  echo "  - If distributing direct-download, test on a separate Mac (or a clean user account) with Gatekeeper enabled." >&3
fi
if [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
  echo "  - For Mac App Store: TestFlight (Mac) delivers the uploaded build for QA; App Store review consumes the same upload." >&3
fi
if [[ "${ENABLE_IOS:-0}" == "1" ]]; then
  echo "  - For iOS: TestFlight delivers the uploaded build for QA; App Store review consumes the same upload." >&3
fi

write_bumped_version_to_env
write_cfbundle_version_to_env
echo "✅ Done" >&3
if [[ "$MAC_DISTRIBUTION" == "developer-id" ]]; then
  echo "App: $APP_PATH" >&3
  if [[ "$ENABLE_ZIP" == "1" ]]; then
    echo "Zip: $ZIP_PATH" >&3
  else
    echo "Zip: (not created — ENABLE_ZIP=0)" >&3
  fi
  if [[ "$ENABLE_DMG" == "1" ]]; then
    echo "DMG: $DMG_PATH" >&3
  else
    echo "DMG: (not created — ENABLE_DMG=0)" >&3
  fi
fi
if [[ "$MAC_DISTRIBUTION" == "app-store" ]]; then
  echo "MAS .pkg: ${MAS_PKG_PATH:-<not produced>}" >&3
fi
if [[ "${ENABLE_IOS:-0}" == "1" ]]; then
  echo "IPA: ${IOS_IPA_PATH:-<not produced>}" >&3
fi

# Cleanup script-generated temp entitlements file only (user-provided files
# are never deleted). MAS doesn't generate a temp entitlements file, so the
# variable may be unset.
/bin/rm -f "${_ENTITLEMENTS_TMP:-}" 2>/dev/null || true
