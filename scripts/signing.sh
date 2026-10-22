#!/bin/bash
# Sourced by build scripts. Development remains usable without Apple credentials.
MYEQ_SIGNING_MODE=${MYEQ_SIGNING_MODE:-development}
case "$MYEQ_SIGNING_MODE" in
  development) MYEQ_APPLICATION_IDENTITY=- ;;
  production)
    : "${MYEQ_APPLICATION_IDENTITY:?Developer ID Application identity required}"
    : "${MYEQ_INSTALLER_IDENTITY:?Developer ID Installer identity required}"
    : "${MYEQ_TEAM_ID:?Apple developer Team ID required}"
    [[ "$MYEQ_APPLICATION_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Invalid application signing identity.' >&2; exit 1; }
    [[ "$MYEQ_INSTALLER_IDENTITY" == 'Developer ID Installer:'* ]] || { echo 'Invalid installer signing identity.' >&2; exit 1; }
    ;;
  *) echo 'MYEQ_SIGNING_MODE must be development or production.' >&2; exit 1 ;;
esac
sign_code() {
  local target=$1 identifier=$2
  local args=(--force --sign "$MYEQ_APPLICATION_IDENTITY" --identifier "$identifier" --options runtime)
  if [ "$MYEQ_SIGNING_MODE" = production ]; then args+=(--timestamp); fi
  /usr/bin/codesign "${args[@]}" "$target"
  /usr/bin/codesign --verify --strict "$target"
}
