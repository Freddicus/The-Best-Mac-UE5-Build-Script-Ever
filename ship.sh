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
  local out id
  out="$(/usr/bin/xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --no-wait --output-format json 2>&1)"
  echo "$out" >&2
  id="$(printf '%s' "$out" | /usr/bin/sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | /usr/bin/head -n 1)"
  if [[ -z "$id" ]]; then
    die "Notary submit failed for $label (no submission id)."
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

maybe_generate_workspace_interactively() {
  # Offer to generate the Xcode workspace using Unreal's GenerateProjectFiles script.
  # Only runs in interactive terminals.
  # Requires UE_ROOT and UPROJECT_PATH.

  # If stdin is not a TTY, we cannot prompt.
  if [[ ! -t 0 ]]; then
    return 1
  fi

  local gen_script
  gen_script="$UE_ROOT/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh"

  if [[ ! -x "$gen_script" ]]; then
    warn "GenerateProjectFiles.sh not found/executable at: $gen_script"
    warn "If you installed Unreal elsewhere, pass --ue-root or set UE_ROOT."
    return 1
  fi

  echo "No .xcworkspace found." >&3
  echo "I can try to generate it now using Unreal's GenerateProjectFiles." >&3
  read -r -p "Generate Xcode workspace now? (Y/n) " ans
  if [[ "${ans:-Y}" =~ ^[Nn]$ ]]; then
    return 1
  fi

  info "Generating Xcode workspace via GenerateProjectFiles.sh"
  "$gen_script" -project="$UPROJECT_PATH" -game
  return 0
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
  echo "REPO_ROOT:         $REPO_ROOT" >&3
  echo "UPROJECT_PATH:     $UPROJECT_PATH" >&3
  echo "UE_ROOT:           $UE_ROOT" >&3
  echo "UAT (RunUAT.sh):   $SCRIPTS/RunUAT.sh" >&3
  echo "UE_EDITOR:         $UE_EDITOR" >&3
  echo "BUILD_DIR:         $BUILD_DIR" >&3
  echo "LOG_DIR:           $LOG_DIR" >&3
  echo "SHORT_NAME:        $SHORT_NAME" >&3
  echo "LONG_NAME:         $LONG_NAME" >&3
  echo "USE_XCODE_EXPORT:  $USE_XCODE_EXPORT" >&3
  echo "CLEAN_BUILD_DIR:   $CLEAN_BUILD_DIR" >&3
  echo "DRY_RUN:           $DRY_RUN" >&3
  echo "PRINT_CONFIG:      $PRINT_CONFIG" >&3
  echo "NOTARIZE:          ${NOTARIZE:-<unset>}" >&3
  echo "ENABLE_STEAM:      $ENABLE_STEAM" >&3
  echo "WRITE_STEAM_APPID: $WRITE_STEAM_APPID" >&3
  echo "MACOS_ICON_SYNC:   $MACOS_ICON_SYNC" >&3
  echo "MACOS_ICON_XCASSETS: ${MACOS_ICON_XCASSETS:-<unset>}" >&3
  echo "MACOS_APPICON_SET_NAME: ${MACOS_APPICON_SET_NAME:-<unset>}" >&3
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
    echo "MARKETING_VERSION: ${MARKETING_VERSION:-<unset, will default to 1.0.0>}" >&3
    echo "ENABLE_GAME_MODE:  ${ENABLE_GAME_MODE:-<unset, will default to YES>}" >&3
    echo "APP_CATEGORY:      ${APP_CATEGORY:-<unset, existing xcconfig value preserved>}" >&3
    echo "XCCONFIG:          $REPO_ROOT/Intermediate/ProjectFiles/XcconfigsMac/${LONG_NAME}.xcconfig" >&3
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
  if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
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
  local new_line="VERSION_STRING=\"$VERSION_STRING\""
  local tmp _line

  if [[ ! -f "$ENV_FILE" ]]; then
    printf '%s\n' "$new_line" > "$ENV_FILE"
    good "Created $ENV_FILE with $new_line"
    return 0
  fi

  if /usr/bin/grep -q "^VERSION_STRING=" "$ENV_FILE"; then
    tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}env_update_XXXXXX")"
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      if [[ "$_line" == VERSION_STRING=* ]]; then
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

# Stamp Info.plist-related keys in the UE-generated xcconfig before Xcode archive.
# The xcconfig lives at: Intermediate/ProjectFiles/XcconfigsMac/<LONG_NAME>.xcconfig
# It is generated by UE's GenerateProjectFiles — this function only rewrites the keys
# listed below; everything else is left untouched.
#
# Keys written:
#   CURRENT_PROJECT_VERSION              (CFBundleVersion)             — only when VERSION_MODE != NONE
#   MARKETING_VERSION                    (CFBundleShortVersionString)  — always; defaults to 1.0.0
#   INFOPLIST_KEY_LSApplicationCategoryType                            — only when APP_CATEGORY is set
#   INFOPLIST_KEY_LSSupportsGameMode  \  placed immediately after      — always; controlled by ENABLE_GAME_MODE
#   INFOPLIST_KEY_GCSupportsGameMode  /  LSApplicationCategoryType     — (defaults YES)
update_xcconfig_versions() {
  local _xcconfig_path="$REPO_ROOT/Intermediate/ProjectFiles/XcconfigsMac/${LONG_NAME}.xcconfig"

  if [[ ! -f "$_xcconfig_path" ]]; then
    info "xcconfig not found at $_xcconfig_path — skipping Info.plist stamp (run GenerateProjectFiles first)"
    return 0
  fi

  # CURRENT_PROJECT_VERSION — only meaningful when we have a version string.
  local _bundle_version=""
  if [[ "$VERSION_MODE" != "NONE" ]]; then
    _bundle_version="$(_resolve_version_string)"
  fi

  # MARKETING_VERSION — user-visible display version (CFBundleShortVersionString).
  local _marketing_ver="${MARKETING_VERSION:-}"
  if [[ -z "$_marketing_ver" ]]; then
    warn "MARKETING_VERSION not set — defaulting to 1.0.0 (set MARKETING_VERSION in .env or pass --marketing-version)"
    _marketing_ver="1.0.0"
  fi

  # ENABLE_GAME_MODE — stamps LSSupportsGameMode + GCSupportsGameMode immediately
  # after INFOPLIST_KEY_LSApplicationCategoryType.
  local _game_mode_raw="${ENABLE_GAME_MODE:-}"
  if [[ -z "$_game_mode_raw" ]]; then
    warn "ENABLE_GAME_MODE not set — defaulting to YES (set ENABLE_GAME_MODE=0 in .env or pass --no-game-mode to disable)"
    _game_mode_raw="1"
  fi
  local _game_mode_val="NO"
  [[ "$_game_mode_raw" == "1" ]] && _game_mode_val="YES"

  # APP_CATEGORY — optional override for INFOPLIST_KEY_LSApplicationCategoryType.
  local _app_category="${APP_CATEGORY:-}"

  local _tmp _line
  local _found_cpv=0 _found_mv=0 _found_cat=0
  _tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}xcconfig_update_XXXXXX")"

  while IFS= read -r _line || [[ -n "$_line" ]]; do
    if [[ "$_line" == CURRENT_PROJECT_VERSION* && -n "$_bundle_version" ]]; then
      printf '%s\n' "CURRENT_PROJECT_VERSION = $_bundle_version"
      _found_cpv=1
    elif [[ "$_line" == MARKETING_VERSION* ]]; then
      printf '%s\n' "MARKETING_VERSION = $_marketing_ver"
      _found_mv=1
    elif [[ "$_line" == INFOPLIST_KEY_LSApplicationCategoryType* ]]; then
      # Write the category line (override value if APP_CATEGORY is set, else preserve).
      if [[ -n "$_app_category" ]]; then
        printf '%s\n' "INFOPLIST_KEY_LSApplicationCategoryType = $_app_category"
      else
        printf '%s\n' "$_line"
      fi
      # Always place game mode keys immediately after the category line.
      printf '%s\n' "INFOPLIST_KEY_LSSupportsGameMode = $_game_mode_val"
      printf '%s\n' "INFOPLIST_KEY_GCSupportsGameMode = $_game_mode_val"
      _found_cat=1
    elif [[ "$_line" == INFOPLIST_KEY_LSSupportsGameMode* || "$_line" == INFOPLIST_KEY_GCSupportsGameMode* ]]; then
      # Suppress old positions — these are now anchored after LSApplicationCategoryType.
      :
    else
      printf '%s\n' "$_line"
    fi
  done < "$_xcconfig_path" > "$_tmp"

  if [[ "$_found_cpv" -eq 0 && -n "$_bundle_version" ]]; then
    printf '%s\n' "CURRENT_PROJECT_VERSION = $_bundle_version" >> "$_tmp"
  fi
  if [[ "$_found_mv" -eq 0 ]]; then
    printf '%s\n' "MARKETING_VERSION = $_marketing_ver" >> "$_tmp"
  fi
  # If LSApplicationCategoryType was never found, append the category (if overriding)
  # and the game mode keys at the end as a fallback.
  if [[ "$_found_cat" -eq 0 ]]; then
    if [[ -n "$_app_category" ]]; then
      printf '%s\n' "INFOPLIST_KEY_LSApplicationCategoryType = $_app_category" >> "$_tmp"
    fi
    printf '%s\n' "INFOPLIST_KEY_LSSupportsGameMode = $_game_mode_val" >> "$_tmp"
    printf '%s\n' "INFOPLIST_KEY_GCSupportsGameMode = $_game_mode_val" >> "$_tmp"
  fi

  /bin/mv "$_tmp" "$_xcconfig_path"
  if [[ -n "$_bundle_version" ]]; then
    good "Stamped $_xcconfig_path → CURRENT_PROJECT_VERSION=$_bundle_version, MARKETING_VERSION=$_marketing_ver, game mode=$_game_mode_val"
  else
    good "Stamped $_xcconfig_path → MARKETING_VERSION=$_marketing_ver, game mode=$_game_mode_val"
  fi
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
      # Offer to generate the workspace interactively.
      if maybe_generate_workspace_interactively; then
        # Re-scan after generation.
        found=()
        while IFS= read -r line; do
          [[ -n "$line" ]] && found+=("$line")
        done < <(/usr/bin/find "$REPO_ROOT" -maxdepth 2 -type d -name '*.xcworkspace' 2>/dev/null)

        if [[ "${#found[@]}" -eq 1 ]]; then
          XCODE_WORKSPACE="$(/usr/bin/basename "${found[0]}")"
          WORKSPACE="${found[0]}"
          info "Auto-detected workspace after generation: $WORKSPACE"
          return 0
        fi

        # Fall through to multi-candidate handling below.
        if [[ "${#found[@]}" -eq 0 ]]; then
          die "GenerateProjectFiles completed, but no .xcworkspace was found under REPO_ROOT. Set XCODE_WORKSPACE explicitly."
        fi
      else
        die "No .xcworkspace found under REPO_ROOT. Generate it (GenerateProjectFiles) or set XCODE_WORKSPACE."
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

seed_macos_icon_assets_for_workspace() {
  # Make workspace projects consume a repo-local, source-controlled macOS asset catalog.
  # This avoids depending on UE engine-global Assets.xcassets for app icons.
  [[ "$USE_XCODE_EXPORT" == "1" ]] || return 0
  [[ "${MACOS_ICON_SYNC:-0}" == "1" ]] || return 0

  [[ -f "$WORKSPACE/contents.xcworkspacedata" ]] || die "Workspace metadata missing: $WORKSPACE/contents.xcworkspacedata"
  [[ -d "$MACOS_ICON_XCASSETS" ]] || die "Configured macOS icon catalog not found: $MACOS_ICON_XCASSETS"

  local stage_root stage_catalog
  stage_root="$REPO_ROOT/Intermediate/SourceControlled"
  stage_catalog="$stage_root/Assets.xcassets"

  /bin/rm -rf "$stage_catalog"
  /bin/mkdir -p "$stage_catalog"
  /usr/bin/rsync -a --delete "$MACOS_ICON_XCASSETS"/ "$stage_catalog"/

  # Xcode expects "AppIcon" by default. If the source-controlled catalog uses a custom
  # appiconset name, mirror it to AppIcon so we do not require build setting edits.
  local source_appicon_name
  source_appicon_name="${MACOS_APPICON_SET_NAME:-}"
  if is_placeholder "$source_appicon_name"; then
    if [[ -d "$stage_catalog/AppIcon.appiconset" ]]; then
      source_appicon_name="AppIcon"
    else
      source_appicon_name="$(first_appiconset_name_in_catalog "$stage_catalog")"
    fi
  fi

  if is_placeholder "$source_appicon_name" || [[ ! -d "$stage_catalog/$source_appicon_name.appiconset" ]]; then
    die "No usable *.appiconset found in $MACOS_ICON_XCASSETS (set MACOS_APPICON_SET_NAME if needed)."
  fi

  if [[ "$source_appicon_name" != "AppIcon" ]]; then
    /bin/rm -rf "$stage_catalog/AppIcon.appiconset"
    /bin/cp -R "$stage_catalog/$source_appicon_name.appiconset" "$stage_catalog/AppIcon.appiconset"
  fi

  if [[ ! -f "$stage_catalog/Contents.json" ]]; then
    /bin/cat > "$stage_catalog/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
  fi

  local stage_catalog_abs escaped_path workspace_xml rel_proj pbxproj changed_count
  stage_catalog_abs="$(abspath_existing "$stage_catalog")"
  [[ -n "$stage_catalog_abs" ]] || die "Unable to resolve staged asset catalog path: $stage_catalog"
  escaped_path="$(printf '%s\n' "$stage_catalog_abs" | /usr/bin/sed 's/[&#\\]/\\&/g')"
  workspace_xml="$WORKSPACE/contents.xcworkspacedata"
  changed_count=0

  while IFS= read -r rel_proj; do
    [[ -n "$rel_proj" ]] || continue
    pbxproj="$REPO_ROOT/$rel_proj/project.pbxproj"
    if [[ ! -f "$pbxproj" ]]; then
      warn "Workspace project missing (skipping icon path patch): $pbxproj"
      continue
    fi
    if ! /usr/bin/grep -q 'folder.assetcatalog; name = "Assets.xcassets";' "$pbxproj"; then
      continue
    fi
    /usr/bin/sed -i '' \
      "/folder\\.assetcatalog; name = \"Assets\\.xcassets\"/ s#path = \"[^\"]*\";#path = \"$escaped_path\";#" \
      "$pbxproj"
    changed_count=$((changed_count + 1))
  done < <(
    /usr/bin/grep -Eo 'location = "group:[^"]+\.xcodeproj"' "$workspace_xml" \
      | /usr/bin/sed -E 's/^location = "group:([^"]+)\.xcodeproj"$/\1.xcodeproj/' \
      | /usr/bin/sort -u
  )

  if [[ "$changed_count" -eq 0 ]]; then
    warn "No workspace project references to Assets.xcassets were patched for icon seeding."
  else
    info "Seeded macOS icon catalog from: $MACOS_ICON_XCASSETS"
    info "Workspace projects patched to use: $stage_catalog_abs"
  fi
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
BUILD_DIR_REL="${BUILD_DIR_REL:-Build}"
LOG_DIR_REL="${LOG_DIR_REL:-Logs}"

SHORT_NAME="${SHORT_NAME:-}"
LONG_NAME="${LONG_NAME:-}"

USE_XCODE_EXPORT="${USE_XCODE_EXPORT:-1}"
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

MACOS_ICON_SYNC="${MACOS_ICON_SYNC:-1}"
MACOS_ICON_XCASSETS="${MACOS_ICON_XCASSETS:-}"
MACOS_APPICON_SET_NAME="${MACOS_APPICON_SET_NAME:-}"

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
APP_CATEGORY="${APP_CATEGORY:-}"


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
  --development-team TEAMID
  --sign-identity "Developer ID Application: ... (TEAMID)"
  --export-plist PATH
  --notary-profile NAME

  --short-name NAME
  --long-name NAME

  --xcode-export / --no-xcode-export
  --clean-build-dir / --no-clean-build-dir
  --dry-run / --no-dry-run
  --print-config / --no-print-config

  --steam / --no-steam
  --write-steam-appid / --no-write-steam-appid
  --steam-app-id ID
  --steam-dylib-src PATH

  --macos-icon-sync / --no-macos-icon-sync
  --macos-icon-xcassets PATH
  --macos-appicon-set-name NAME

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
  --app-category STRING              (INFOPLIST_KEY_LSApplicationCategoryType, e.g. public.app-category.games)
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

    --development-team)     DEVELOPMENT_TEAM="$2"; shift 2 ;;
    --sign-identity)        SIGN_IDENTITY="$2"; shift 2 ;;
    --export-plist)         EXPORT_PLIST="$2"; shift 2 ;;
    --notary-profile)       NOTARY_PROFILE="$2"; shift 2 ;;

    --short-name)           SHORT_NAME="$2"; shift 2 ;;
    --long-name)            LONG_NAME="$2"; shift 2 ;;

    --xcode-export)         USE_XCODE_EXPORT="1"; shift ;;
    --no-xcode-export)      USE_XCODE_EXPORT="0"; shift ;;
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

    --macos-icon-sync)      MACOS_ICON_SYNC="1"; shift ;;
    --no-macos-icon-sync)   MACOS_ICON_SYNC="0"; shift ;;
    --macos-icon-xcassets)  MACOS_ICON_XCASSETS="$2"; CLI_SET_MACOS_ICON_XCASSETS=1; shift 2 ;;
    --macos-appicon-set-name) MACOS_APPICON_SET_NAME="$2"; shift 2 ;;

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
    --app-category)             APP_CATEGORY="$2"; shift 2 ;;
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
autodetect_workspace_guess_if_needed
autodetect_export_plist_if_needed
autodetect_steam_if_needed
autodetect_steam_dylib_src_from_engine_if_needed

# Default macOS icon catalog location is source-controlled in repo root.
if is_placeholder "${MACOS_ICON_XCASSETS:-}"; then
  MACOS_ICON_XCASSETS="$REPO_ROOT/macOS-SourceControlled.xcassets"
fi
if [[ "$MACOS_ICON_XCASSETS" != /* ]]; then
  MACOS_ICON_XCASSETS="$(abspath_from "$REPO_ROOT" "$MACOS_ICON_XCASSETS")"
fi

# Derive common paths (after CLI parsing/autodetect)
UPROJECT_PATH="${UPROJECT_PATH:-$REPO_ROOT/$UPROJECT_NAME}"
WORKSPACE="${WORKSPACE:-$REPO_ROOT/$XCODE_WORKSPACE}"
SCHEME="$XCODE_SCHEME"

SCRIPTS="$UE_ROOT/$UAT_SCRIPTS_SUBPATH"
UE_EDITOR="$UE_ROOT/$UE_EDITOR_SUBPATH"

# Artifact roots
BUILD_DIR="$REPO_ROOT/$BUILD_DIR_REL"
LOG_DIR="$REPO_ROOT/$LOG_DIR_REL"

# Normalize a few important paths to absolute paths when possible.
# (This helps when the user passes relative paths via env/CLI.)
if [[ -d "$WORKSPACE" ]]; then
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
require_not_placeholder "SIGN_IDENTITY" "$SIGN_IDENTITY" "Example: Developer ID Application: Your Company (ABCDE12345)"
require_not_placeholder "SHORT_NAME" "$SHORT_NAME" "Example: MG"
require_not_placeholder "LONG_NAME" "$LONG_NAME" "Example: MyGame"

# Xcode inputs are only required if you use the Xcode archive/export steps.
if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  # Ensure derived paths are available to autodetect.
  WORKSPACE="${WORKSPACE:-$REPO_ROOT/$XCODE_WORKSPACE}"
  SCHEME="$XCODE_SCHEME"

  # Try auto-detect first (helps new users).
  autodetect_workspace_if_needed
  autodetect_scheme_if_needed

  require_not_placeholder "EXPORT_PLIST" "$EXPORT_PLIST" "Point at an ExportOptions.plist compatible with Developer ID exports"
  require_not_placeholder "XCODE_WORKSPACE" "$XCODE_WORKSPACE" "Example: YourProject (Mac).xcworkspace"
  require_not_placeholder "XCODE_SCHEME" "$XCODE_SCHEME" "Example: YourProject"
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

# Logging (keep logs OUTSIDE Build/, since Build/ is often wiped each run)
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build_$(date +%Y-%m-%d_%H-%M-%S).log"
exec >>"$LOG_FILE" 2>&1
echo "Log file: $LOG_FILE" >&3

trap on_error_exit ERR
trap 'restore_content_version_file' EXIT

# Build outputs
ARCHIVE_PATH="$BUILD_DIR/${SHORT_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/${SHORT_NAME}-export"
ZIP_PATH="$BUILD_DIR/${LONG_NAME}.zip"

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

# Verify the signing identity exists in the keychain before the multi-hour build.
# A typo or expired cert will fail here rather than after UAT finishes cooking.
if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -qF "$SIGN_IDENTITY"; then
  echo "Available Developer ID codesigning identities:" >&3
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep "Developer ID" >&3 || echo "  (none found)" >&3
  die "SIGN_IDENTITY not found in keychain: $SIGN_IDENTITY"
fi
good "Signing identity found in keychain."

# Xcode steps are optional
if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  # Xcode workspaces are directory bundles (".xcworkspace" folders), not regular files.
  [[ -d "$WORKSPACE" ]] || die "Xcode workspace not found (expected a .xcworkspace directory): $WORKSPACE"
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode and the Command Line Tools."
fi

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

# Export options plist must exist if you are exporting
if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  [[ -f "$EXPORT_PLIST" ]] || die "ExportOptions.plist not found: $EXPORT_PLIST"
fi

if [[ "$USE_XCODE_EXPORT" == "1" && "$MACOS_ICON_SYNC" == "1" ]]; then
  if [[ ! -d "$MACOS_ICON_XCASSETS" ]]; then
    if [[ "${CLI_SET_MACOS_ICON_XCASSETS:-0}" == "1" ]]; then
      die "Configured --macos-icon-xcassets path not found: $MACOS_ICON_XCASSETS"
    fi
    warn "macOS icon catalog not found at default path: $MACOS_ICON_XCASSETS"
    warn "Continuing without macOS icon catalog seeding (pass --no-macos-icon-sync to silence this)."
    MACOS_ICON_SYNC="0"
  fi
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
  if [[ "$VERSION_MODE" != "NONE" ]]; then
    steps="stamp Content/$VERSION_CONTENT_DIR/version.txt → UAT BuildCookRun"
  else
    steps="UAT BuildCookRun"
  fi
  if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
    steps="$steps → Xcode archive/export"
  else
    steps="$steps → (skip Xcode archive/export)"
  fi
  steps="$steps → codesign"
  if [[ "$ENABLE_ZIP" == "1" ]]; then
    steps="$steps → zip"
  fi
  if [[ "$ENABLE_DMG" == "1" ]]; then
    steps="$steps → DMG create+sign"
    if [[ "$FANCY_DMG" == "1" ]]; then
      steps="$steps → DMG Finder layout (experimental)"
    fi
  fi
  if [[ "$NOTARIZE_ENABLED" -eq 1 ]]; then
    steps="$steps → notarize+staple"
  fi
  if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
    echo "Would wipe build dir: $BUILD_DIR" >&3
  fi
  echo "Would run: $steps" >&3
  exit 0
fi

echo "== Prep output locations ==" >&3
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$ZIP_PATH"
if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
  warn "CLEAN_BUILD_DIR=1 — wiping entire build dir: $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

ensure_game_ini_staging_entry
write_version_to_content
update_xcconfig_versions

info "Building game (UAT BuildCookRun)"

"$SCRIPTS/RunUAT.sh" BuildCookRun \
  -unrealexe="$UE_EDITOR" \
  -project="$UPROJECT_PATH" \
  -noP4 -build -cook -pak -iostore \
  -targetplatform=Mac -clientconfig="$UE_CLIENT_CONFIG" \
  -stage -package \
  -archive -archivedirectory="$BUILD_DIR" \
  -utf8output -verbose -specifiedarchitecture=arm64+x86_64

echo "== Note: UE clientconfig=$UE_CLIENT_CONFIG, Xcode configuration=$XCODE_CONFIG ==" >&3

if [[ "$USE_XCODE_EXPORT" == "1" ]]; then
  seed_macos_icon_assets_for_workspace

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
    OTHER_CODE_SIGN_FLAGS="--timestamp"

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

echo "REMINDER: Test your distribution path." >&3
echo "  - If distributing via a launcher (Steam, Epic, etc.), test launching from that launcher." >&3
echo "  - If distributing direct-download, test on a separate Mac (or a clean user account) with Gatekeeper enabled." >&3

write_bumped_version_to_env
echo "✅ Done" >&3
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

# Cleanup script-generated temp entitlements file only (user-provided files are never deleted).
/bin/rm -f "${_ENTITLEMENTS_TMP:-}" 2>/dev/null || true
