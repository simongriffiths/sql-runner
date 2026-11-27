#!/usr/bin/env bash
set -euo pipefail

# Builds road-secrets and installs it for the current user (road-secrets spec Section 10).
#
# road-secrets keeps ROAD dev and test passwords in the login keychain. Each Keychain item trusts
# exactly one program, ~/.local/bin/road-secrets, so the binary lives at that fixed path, outside
# every repository. It is never copied into a project.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${REPO_ROOT}/tools/road-secrets"
INSTALL_DIR="${HOME}/.local/bin"
TARGET="${INSTALL_DIR}/road-secrets"

# 1. Swift.
if ! command -v swift >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
  echo "[ERROR] Swift not found. Install Apple's Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

# 2. Build. The Command Line Tools toolchain sometimes fails a build with "plugin for module ...
# not found", occasionally twice in a row; a later attempt succeeds, so try up to three times.
echo "[INFO] Building road-secrets (swift build -c release)"
if ! (cd "${PACKAGE_DIR}" && swift build -c release >/dev/null 2>&1) \
  && ! (cd "${PACKAGE_DIR}" && swift build -c release >/dev/null 2>&1); then
  (cd "${PACKAGE_DIR}" && swift build -c release)
fi
BUILT="$(cd "${PACKAGE_DIR}" && swift build -c release --show-bin-path)/road-secrets"
if [[ ! -x "${BUILT}" ]]; then
  echo "[ERROR] Build finished but ${BUILT} was not found" >&2
  exit 1
fi

# 3. Install.
mkdir -p "${INSTALL_DIR}"
cp "${BUILT}" "${TARGET}.new"
chmod 755 "${TARGET}.new"
mv -f "${TARGET}.new" "${TARGET}"
echo "[INFO] Installed ${TARGET}"

# 4. PATH.
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    echo "[WARN] ${INSTALL_DIR} is not on PATH. Add this line to ~/.zshrc:"
    # shellcheck disable=SC2016
    echo '  export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac

# 5. road-atlas.
ATLAS="${ROAD_ATLAS:-${HOME}/Projects/road-atlas}"
if [[ ! -f "${ATLAS}/environments.conf" || ! -f "${ATLAS}/databases.conf" ]]; then
  echo "[WARN] road-atlas not found at ${ATLAS}. set refuses to run without it."
  echo "[WARN] Set ROAD_ATLAS to the road-atlas checkout, for example in ~/.zshrc."
fi

# 6. init: checks that the login keychain works for this binary.
"${TARGET}" init

# 7. Rebuild warning (spec Section 9.2).
cat <<'WARN'
[WARN] Every rebuild gives road-secrets a new identity. Afterwards, the first read of each
[WARN] Keychain item shows an "Always Allow" prompt on this Mac's screen. Click Always Allow
[WARN] once per item. Do not rebuild just before leaving an unattended run: the run would
[WARN] stop at the first prompt.
WARN
