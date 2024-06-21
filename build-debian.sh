#!/bin/bash
BUILD_DIR="build"
PACKAGE_NAME="git-metadata"
PACKAGE_DIR="${BUILD_DIR}/${PACKAGE_NAME}"
SCRIPT_DESTINATION="${PACKAGE_DIR}/usr/local/bin"
MANUAL_DESTINATION="${PACKAGE_DIR}/usr/local/share/man/man1"
COMPLETION_DESTINATION="${PACKAGE_DIR}/etc/bash_completion.d"
CONTROL_FILE="${PACKAGE_DIR}/DEBIAN/control"
CHANGELOG_FILE="${PACKAGE_DIR}/DEBIAN/changelog"
EXECUTABLE_FILE="${SCRIPT_DESTINATION}/git-metadata"
declare -a VERSION_TO_SET=("${CONTROL_FILE}" "${CHANGELOG_FILE}" "${EXECUTABLE_FILE}")
FILE_NAME_PROVIDER=""
RELEASE=""

set_version_and_date() {
  # always use snapshot unless it is a Release job for tagged commit
  if [ "${RELEASE}" ]; then
    VERSION=$(git describe --abbrev=0 2> /dev/null || echo "0.0.0")
  else
    VERSION="$(git describe --abbrev=0 2> /dev/null || echo "0.0.0")-snapshot"
  fi
  for file in "${VERSION_TO_SET[@]}"; do
    sed -i "s/@GIT-METADATA-VERSION@/${VERSION}/g" "${file}"
  done
  TIME=$(date -R 2>/dev/null)
  sed -i "s/@GIT-METADATA-RELEASE-TIME@/${TIME}/g" ${CHANGELOG_FILE}
}

copy_files() {
  mkdir -p ${SCRIPT_DESTINATION}
  mkdir -p ${MANUAL_DESTINATION}
  mkdir -p ${COMPLETION_DESTINATION}
  cp -R DEBIAN ${PACKAGE_DIR}/
  asciidoctor -b manpage doc/git-metadata-man.ad -o - | gzip -c > ${MANUAL_DESTINATION}/git-metadata.1.gz
  cp git-metadata.sh ${EXECUTABLE_FILE}
  cp git-metadata-completion ${COMPLETION_DESTINATION}/
}

parse_cli() {
  for arg in "$@"; do
    case $arg in
      --file-name-provider=*) FILE_NAME_PROVIDER="${arg#*=}" ;;
      --release=*) RELEASE="${arg#*=}" ;;
      *) echo "Invalid Argument $arg"; exit 1 ;;
    esac
  done
}

parse_cli "$@"
cd "$(dirname "$(realpath "$0")")" || exit 1
copy_files
set_version_and_date
DEBIAN_FILE_NAME="${PACKAGE_NAME}-${VERSION}_all.deb"
cd "${BUILD_DIR}" && dpkg-deb -b "${PACKAGE_NAME}" "${DEBIAN_FILE_NAME}"
if [ "${FILE_NAME_PROVIDER}" ]; then
  echo "$DEBIAN_FILE_NAME" > "${FILE_NAME_PROVIDER}"
fi