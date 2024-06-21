#!/bin/bash

##########################################################################
# git-metadata: git version control of metadata for binaries
# Copyright (C) 2024 Geometrie Profi

#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.

#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.

#   You should can check the terms of the GNU General Public License at
#   <https://www.gnu.org/licenses/>.
##########################################################################

set -o pipefail

###################################################################################################
######## Version for serialization of metadata file ###############################################
METADATA_SERIALIZATION_VERSION="1.0"   ## major.minor version
######## Version of tool, set during build process ################################################
GIT_METADATA_VERSION='@GIT-METADATA-VERSION@'

###################################################################################################
######## Constants, should not be modified by the script ##########################################
###################################################################################################
GIT_DIR='.git'
METADATA='.bin-metadata'
BINARY_COMMIT='.bin-commit'
BINARY_EXCLUDE='.bin-exclude'
GIT_IGNORE='.gitignore'
GIT_CONFIG='.gitconfig'
declare -a FILES_REQUIRED_GIT_IGNORE_BIN_TYPE=("${GIT_IGNORE}" "${METADATA}" "${BINARY_EXCLUDE}" "${GIT_CONFIG}")
declare -a PATTERN_GIT_IGNORE_STANDARD_TYPE=("**/build" "*.gz" "*.jpg" "*.pdf" "*.tar" "*.zip")
CONFIG_METADATA_BRANCH='metadata.branch'  ## required git config key: value holds the branch used for metadata tracking, set with init call
CONFIG_BINARY='remote-binary'  ## optional data for a remote binary in git config, usage remote-binary.alpha = ... if alpha is the name of the remote
METADATA_SERIALIZATION_KEY="metadata-serialization-version:" ## version key for serialization of metadata file
declare -a INIT_TYPE=("binary" "standard")
RED='\033[0;31m'          # Red
GREEN='\033[0;32m'        # Green
PINK='\033[1;35m'         # Link Purple
COLOR_OFF='\033[0m'       # Text Reset
TRUE="true"
FAILED_RESULT='failed'
CONSTANT_SAME_AS='is the same as'
CONSTANT_AHEAD_OF='is ahead of'
CONSTANT_BEHIND_OF='is behind of'
CONSTANT_DIVERGENT_TO='is divergent to'
CONSTANT_SPACE='    '

###################################################################################################
######## Variables which can be modified ##########################################################
###################################################################################################
DIFF_FORMAT=(--color)     # classic diff options

###################################################################################################
######## Common helper functions ##################################################################
###################################################################################################

####### Prints success to stdout and exits ########################################################
####### argument $1: printed success message
exit_on_success() {
  echo "$1"
  exit 0
}

######## Mainly used to export a non-successful exit from subshell to current shell ###############
######## argument $1: result code, exit with error if result code non-zero
######## argument $2: optional error message
exit_on_error() {
  case $1 in
    0) return 0 ;;
    [1-9]) echo "$2"; exit "$1" ;;
    *) echo "Internal error: failed initial exit $2 because $1 is not a valid exit code of the script."; exit 1
  esac
}
######## Exit if command or retrieval of value failed #############################################
exit_command_fail() {
  exit_on_error 1 "$1"
}
######## Exit on invalid cli arguments ############################################################
exit_wrong_argument() {
  exit_on_error 2 "$1"
}
######## Exit if commit is not in local git history ###############################################
exit_unknown_commit() {
  exit_on_error 7 "$1"
}
######## Exit on unmet requirements for execution of a command ####################################
exit_unmet_requirements() {
  exit_on_error 3 "$1"
}
######## Exit due to an internal error of the script ##############################################
exit_internal_error() {
  exit_on_error 5 "$1"
}

######## Prints an warning message ################################################################
######## argument $1: warning message
print_warning_msg() {
  echo -e "${RED}$1${COLOR_OFF}"
}

######## Returns if first argument matches one of the following arguments #########################
######## argument $1: element to be checked for equality with $K for K>1
array_contains_element() {
  local element="$1"
  shift 1
  for other in "${@}"; do
    if [ "$other" = "$element" ]; then
      return 0
    fi
  done
  return 1
}

######## Retrieves the git branch name in the config used for metadata tracking ###################
######## no arguments
get_config_branch() {
  # error is not printed to Stdout if file GIT_CONFIG does not exist, only error code 1
  git config --file=${GIT_CONFIG} ${CONFIG_METADATA_BRANCH} || git config ${CONFIG_METADATA_BRANCH}
}
######## Retrieves the current branch name of this git repository #################################
######## no arguments
get_current_branch() {
  git branch --show-current
}

######## Retrieves all the defined remote-binary names in the git config ##########################
######## no arguments
get_remote_binary_names() {
  git config --file=${GIT_CONFIG} --get-regexp --name-only ${CONFIG_BINARY} | cut -d'.' -f2
  git config --get-regexp --name-only ${CONFIG_BINARY} | cut -d'.' -f2
}

######## Retrieves if a remote binary is defined in git config ####################################
######## no arguments
has_remote_binary() {
  git config --file=${GIT_CONFIG} --get-regexp --name-only ${CONFIG_BINARY} >/dev/null || git config --get-regexp --name-only ${CONFIG_BINARY} >/dev/null
}

######## Retrieves if a remote git is defined in git config #######################################
######## no arguments
has_remote_git() {
  git config --get-regexp --name-only remote.*.url > /dev/null
}

######## Retrieves all the defined remote git repo names in the git config ########################
######## no arguments
get_remote_git_names() {
  git config --get-regexp --name-only remote.*.url | cut -d'.' -f2
}

######## Retrieves the version of this tool from debian package ###################################
######## no arguments
get_version() {
  echo "$GIT_METADATA_VERSION"
}

######## Retrieves the list of binaries, i.e. files which are not tracked by git ##################
######## no arguments
######## Notice: set 'git config' values core.precomposeunicode = true, core.quotepath = false if filenames odd
get_untracked_file_names() {
  # always need to exclude the file ${BINARY_COMMIT} because it is neither tracked by git nor can it be part of metadata tracking
  if [ -f ${BINARY_EXCLUDE} ] && [ -s ${BINARY_EXCLUDE} ]; then
    git ls-files . --others --exclude="${BINARY_COMMIT}" --exclude-from=${BINARY_EXCLUDE}
  else
    git ls-files . --others --exclude="${BINARY_COMMIT}"
  fi
}

######## Retrieves git commit-sha which contains the latest changes of the metadata file ##########
######## no arguments
get_last_commit_metadata_local() {
  git log -n 1 --pretty=format:%H -- ${METADATA}
}

######## Retrieves git commit-sha which contains the latest changes of the remote metadata file ###
######## argument $1: remote name
get_last_commit_metadata_remote() {
  if [ "$1" = "" ]; then
    exit_internal_error "Require a git remote name!"
  fi
  git log -n 1 --pretty=format:%H "$1/$(get_config_branch)" ${METADATA} 2>/dev/null
}

######## Retrieves if there is a commit, exit code zero only if this is a git repo with a commit ##
######## no arguments
has_a_commit() {
  git log -n 1 --pretty=format:%H > /dev/null 2> /dev/null
}

######## Retrieves the common ancestor of provided git commit-sha #################################
######## arguments $1, $2: commit-sha from git-history of git-metadata config branch
get_common_ancestor() {
  git merge-base "$1" "$2" 2>/dev/null || echo "$FAILED_RESULT"
}

######## Retrieves the commit number of provided commit-sha #######################################
######## argument $1: commit-sha to get commit number of
get_commit_number() {
  git rev-list --count "$1"
}

######## Checks that required tools are installed #################################################
######## no arguments | exit with error if some required tool is missing
check_tools() {
  git --version > /dev/null || exit_unmet_requirements "Require git installation!"
  diff --version > /dev/null || exit_unmet_requirements "Require diff to be installed!"
}

######## Check git repository presence and that HEAD is not detached. #############################
######## no arguments | exit with error if check fails
check_git() {
  if [ ! -d ${GIT_DIR} ]; then
    exit_unmet_requirements "This is not the root of a .git repository."
  fi
  if [ ! "$(find ./ -maxdepth 1 -name ${GIT_DIR})" = "$(find ./ -name ${GIT_DIR})" ]; then
    exit_unmet_requirements "At least one subfolder contains a ${GIT_DIR} directory, submodules are not supported!"
  fi
  if ! git symbolic-ref -q HEAD > /dev/null 2> /dev/null; then
    exit_unmet_requirements "Detached HEADs are not supported by git-metadata."
  fi
}

######## Checks if rsync is installed #############################################################
######## no arguments | exit with error if rsync is not installed
check_rsync_install() {
  rsync --version > /dev/null || exit_unmet_requirements "Require rsync installation!"
}

######## Checks if git has uncommitted changes. ###################################################
######## no arguments
git_has_uncommitted_changes() {
  [ "$(git status -s)" ]
}

######## Check that basic support for metadata tracking was initialized. ##########################
######## no arguments | exit with error if check fails
check_basics_metadata() {
  check_tools
  check_git
  if [ ! -f ${METADATA} ]; then
    exit_unmet_requirements "Missing file ${METADATA}, either metadata tracking has not been initialized yet or this is the wrong branch."
  fi
  local current_branch config_branch
  current_branch=$(get_current_branch) || exit_command_fail "Failed to retrieve the current branch: $current_branch"
  config_branch=$(get_config_branch) || exit_command_fail "Failed to retrieve the config branch: $config_branch"
  if [ ! "$current_branch" = "$config_branch" ]; then
    exit_unmet_requirements "Current branch $current_branch is different than branch $config_branch used for metadata tracking."
  fi
}

######## Retrieves if provided argument is a valid commit sha #####################################
######## argument $1: commit sha to be checked
is_in_local_git_history() {
  git show "$1":"${METADATA}" >/dev/null 2>/dev/null
}

######## Returns argument if it is a valid commit sha, otherwise returns $FAILED_RESULT ###########
######## argument $1: commit sha to be returned if valid commit sha
get_complete_commit_sha_or_fail() {
  git rev-parse --verify "$1" 2>/dev/null || echo "$FAILED_RESULT"
}

######## Retrieves the URL of the binary remote for provided remote name ##########################
######## argument $1: remote name of binary repository defined in git-config
get_binary_remote_url_from_config() {
  git config --file=${GIT_CONFIG} "${CONFIG_BINARY}.$1" || git config "${CONFIG_BINARY}.$1"
}

######### Retrieves if provided argument is the remote name of a binary repo ######################
######## argument $1: remote name of binary repository defined in git-config
is_binary_remote() {
  get_binary_remote_url_from_config "$1" >/dev/null 2>/dev/null
}

######## Retrieves the URL of the binary remote for provided remote name without trailing slash ###
######## argument $1: remote name of binary repository defined in git-config
get_binary_remote_url() {
  local binary_remote_url
  binary_remote_url=$(get_binary_remote_url_from_config "$1") || exit_command_fail "Failed to retrieve the url for binary remote $1 due to $binary_remote_url"
  echo "${binary_remote_url%/}"
}

######## Retrieves if provided argument is the name of a git remote repository ####################
######## argument $1: remote name of git repository defined in git-config
is_git_remote() {
  git config "remote.$1.url" >/dev/null 2>/dev/null
}

######## Retrieves if the repository type of metadata tracking ####################################
######## Binary type means that files which are added to the directory are ignored by git #########
######## no arguments
get_repository_type() {
  # shellcheck disable=SC2063
  if grep -qx "*" "${GIT_IGNORE}"; then
    echo "binary"
  else
    echo "standard"
  fi
}

######## Checks existence and sets remote url entry as in git config for provided remote name. ####
######## argument $1: remote name | exit with error if rsync is not installed or provided argument has no url entry
check_and_set_remote() {
  check_rsync_install

  if [ ! "$1" ]; then
    exit_wrong_argument "Require a remote name."
  fi
  BIN_REMOTE_NAME="$1"
  BIN_REMOTE_URL=$(get_binary_remote_url "$BIN_REMOTE_NAME") || exit_wrong_argument "${BIN_REMOTE_NAME} does not have a remote url in git config."
}

######## Provides the list of metadata for local files not tracked by git #########################
######## no arguments
get_metadata_of_local_binaries() {
  header_metadata_file
  get_untracked_file_names | sort | xargs -d '\n' stat -L --format="%n,%s,%Y,%A"
}

######## Shows the file output of ${METADATA} for provided commit #################################
######## argument $1: commit-sha to retrieve metadata for
get_metadata_from_commit() {
  git show "$1":"${METADATA}" 2>/dev/null || exit_command_fail "Can not read ${METADATA} file for commit-sha $1, it usually means that commit is not in local git history."
}

######## Retrieves the serialization version of the metadata file for provided commit #############
######## argument $1: commit-sha
get_metadata_serialization_version() {
  get_metadata_from_commit "$1" | grep "${METADATA_SERIALIZATION_KEY}" | cut -c $((${#METADATA_SERIALIZATION_KEY} + 1))-
}

######## Difference between metadata ##############################################################
######## argument $1 mandatory: commit-sha of tracked metadata file in git history
######## argument $2 optional: commit-sha of tracked metadata file in git history, if not provided diff is done w.r.t. metadata of local binaries
######## exit code is 1 if there are differences, 21|22 if argument is not a commit sha in local git history
diff_metadata() {
  # process substitution has problems with errors, hence make sure that provided commit-sha are in local git history
  if ! is_in_local_git_history "$1"; then
    return 21
  fi
  if [ "$2" = "" ]; then
    diff "${DIFF_FORMAT[@]}" <(get_metadata_from_commit "$1") <(get_metadata_of_local_binaries)
  else
    if is_in_local_git_history "$2"; then
      diff "${DIFF_FORMAT[@]}" <(get_metadata_from_commit "$1") <(get_metadata_from_commit "$2")
    else
      return 22
    fi
  fi
}

######## Retrieves list of files changes ##########################################################
######## argument $1 mandatory: commit-sha of tracked metadata file in git history
######## argument $2 optional: commit-sha of tracked metadata file in git history, if not provided comparison is done w.r.t. metadata of local binaries
get_changed_files() {
  DIFF_FORMAT=(--new-line-format=$'%L' --old-line-format=$'%L' --unchanged-line-format='')
  diff_metadata "${@}" | rev | cut -d ',' -f4- | rev | sort | uniq -d  ## remove last 3 columns
}

######## Retrieves the git commit-sha for local binary files ######################################
######## no arguments | exit with error if file ${BINARY_COMMIT} not present
get_complete_LOCAL_BIN_SHA() {
  if [ -f ${BINARY_COMMIT} ]; then
    git rev-parse --verify "$(cat ${BINARY_COMMIT})"
  else
    exit_unmet_requirements "Missing file ${BINARY_COMMIT}, status of local binaries is undefined."
  fi
}

######## Retrieves the git commit-sha of remote ${BIN_REMOTE_URL} #################################
######## argument $1 | remote url to used by rsync | exit with error if retrieval fails
get_complete_remote_bin_sha() {
  local tmp_file="/tmp/${BINARY_COMMIT}"
  local remote_commit_file commit_sha
  remote_commit_file="${1}/${BINARY_COMMIT}" || exit_command_fail "$remote_commit_file"
  rsync "$remote_commit_file" /tmp/ || exit_command_fail "Unable to download file ${remote_commit_file}."
  if [ -f ${tmp_file} ]; then
    commit_sha=$(cat $tmp_file)
    local result=$?
    rm -f $tmp_file  # make sure that file is deleted before exit!!
    exit_on_error $result "Failed to read temporary downloaded file $tmp_file: $commit_sha"
    git rev-parse --verify "$commit_sha"
  else
    rm -f $tmp_file
    exit_command_fail "Failed to retrieve the remote binary commit-sha."
  fi
}

######## Retrieves the git commit-sha of remote by remote name ${1} ###############################
######## argument $1 | remote name | exit with error if retrieval fails
get_remote_bin_sha_by_name() {
  if [ ! "$1" ]; then
    exit_internal_error "Require a remote name for retrieval of bin commit-sha."
  fi
  get_complete_remote_bin_sha "$(get_binary_remote_url "$1")" || exit_command_fail "Failed to retrieve the bin commit-sha for $1."
}

######## Retrieves files and folders that should be ignored by rsync. #############################
######## no arguments
get_rsync_ignores() {
  if [ -f ${BINARY_EXCLUDE} ] && [ -s ${BINARY_EXCLUDE} ]; then
    cat ${BINARY_EXCLUDE}
  fi
  echo ".git" && git ls-files .
}

######## Retrieves the comparison status of provided commit sha ###################################
######## mandatory arguments $1 and $2: commit sha to get comparison result for
get_comparison_status() {
  if [ ! "$1" ] || [ ! "$2" ]; then
    exit_internal_error "Require two commit sha as arguments."
  fi
  if [ "$1" = "$2" ]; then
    echo "${CONSTANT_SAME_AS}"
  else
    local common_ancestor
    common_ancestor=$(get_common_ancestor "$1" "$2") || exit_internal_error "Internal error on retrieving the common ancestor of $1 and $2 due to ${common_ancestor}."
    case "$common_ancestor" in
      "$1") echo "${CONSTANT_BEHIND_OF}" ;;
      "$2") echo "${CONSTANT_AHEAD_OF}" ;;
      "${FAILED_RESULT}") exit_unknown_commit "Unable to determine the merge base because $1 or $2 is not in local git history." ;;
      *) echo "${CONSTANT_DIVERGENT_TO}" ;;
    esac
  fi
}

######## Retrieves the commit alias name of the metadata head for local or remote git repository ##
######## optional argument: remote git repository name as in git config
get_name_metadata_commit() {
  if [ ! "$1" ]; then
    echo "metadata-commit@local-git"
  else
    echo "metadata-commit@$1"
  fi
}

######## Retrieves the commit alias name of the commit-sha defined in ${BINARY_COMMIT} ############
######## optional argument: remote binary repository name as in git config
get_name_commit_sha() {
  if [ ! "$1" ]; then
    echo "commit-state@local-bin"
  else
    echo "commit-state@$1"
  fi
}

######## Validates if local file ${METADATA} was serialized with the version of the script ########
######## argument $1: commit-sha | exit if retrieval fails, warning if versions differ
check_serialization_version() {
  local metadata_serial_version
  metadata_serial_version=$(get_metadata_serialization_version "$1") || exit_command_fail "Unable to retrieve version of metadata serialization."
  if [ ! "${metadata_serial_version}" = "${METADATA_SERIALIZATION_VERSION}" ]; then
    print_warning_msg "Warning, metadata committed with serialization version other than serialization version used by the script."
  fi
}

######## Initializes the header for the metadata file #############################################
######## no arguments
header_metadata_file() {
  echo "${METADATA_SERIALIZATION_KEY}${METADATA_SERIALIZATION_VERSION}"
  echo "Filename,Size,Unix-time,Ownership"
}

######## Parsing cli parameter for the sync commands ##############################################
######## mandatory argument: remote name as in git config | optional argument: force action
parse_cli_parameter_sync_command() {
  if [ "$3" ]; then
    exit_wrong_argument "Too many arguments, at most two can be provided for this command."
  fi
  if [ ! "$1" ]; then
    exit_wrong_argument "Require a remote binary name for this command."
  fi
  if [ "$2" ]; then
    if [ "$1" = "--force" ]; then
      FORCE=${TRUE}
      check_and_set_remote "$2"
    elif [ "$2" = "--force" ]; then
      FORCE=${TRUE}
      check_and_set_remote "$1"
    else
      exit_wrong_argument "If two arguments are provided, one of them must be the option '--force'."
    fi
  else
    check_and_set_remote "$1"
  fi
}

######## Exits with error if locally binaries have changed since last update ######################
######## no arguments | requires variable ${LOCAL_BIN_SHA}
exit_error_if_uncommitted_changes() {
  local common_fail_report="Unable to perform the sync command,"
  diff_metadata "$LOCAL_BIN_SHA"
  case "$?" in
    0) return 0 ;;
    1) exit_command_fail "$common_fail_report there are uncommitted changes of metadata." ;;
    21) exit_unknown_commit "$common_fail_report commit-sha $LOCAL_BIN_SHA in $BINARY_COMMIT is not in local git history." ;;
    *) exit_command_fail "$common_fail_report because the diff command failed for unknown reason."
  esac
}

######## Exits with success if remote and local are on the same commit ############################
######## no arguments | requires ${LOCAL_BIN_SHA}, ${REMOTE_BIN_SHA}, ${BINARY_REMOTE_NAME}
exit_success_if_remote_equals_local() {
  if [ "$REMOTE_BIN_SHA" = "$LOCAL_BIN_SHA" ]; then
    exit_on_success "Sync not necessary, remote ${BIN_REMOTE_NAME} and local are equal."
  fi
}

######## Variable Setter used to simplify main functions ##########################################
######## after a successful setter call, the respective variable holds a validated value ##########
set_LOCAL_BIN_SHA() {
  LOCAL_BIN_SHA=$(get_complete_LOCAL_BIN_SHA) || exit_command_fail "Failed to retrieve the commit-sha of local binaries: $LOCAL_BIN_SHA"
  if ! is_in_local_git_history "$LOCAL_BIN_SHA"; then
    exit_unknown_commit "The commit sha $LOCAL_BIN_SHA in file $BINARY_COMMIT is not in local git history."
  fi
}
set_REMOTE_BIN_SHA() {
  REMOTE_BIN_SHA=$(get_complete_remote_bin_sha "$BIN_REMOTE_URL") || exit_command_fail "Failed to retrieve the commit-sha of '$BIN_REMOTE_NAME' binaries: $REMOTE_BIN_SHA"
  if ! is_in_local_git_history "$REMOTE_BIN_SHA"; then
    exit_unknown_commit "The commit sha $REMOTE_BIN_SHA of remote $BIN_REMOTE_NAME is not in local git history."
  fi
}
set_LAST_METADATA_SHA() {
  LAST_METADATA_SHA=$(get_last_commit_metadata_local) || exit_command_fail "Failed to retrieve the last metadata commit-sha: $LAST_METADATA_SHA"
  # do not need to check is_in_local_git_history because if value exists, it is read from local git history
  if [ "$LAST_METADATA_SHA" = "" ]; then
    exit_command_fail "Metadata have not been committed yet."
  fi
}

###################################################################################################
######## Init #####################################################################################
###################################################################################################

######## Remove all .gitignore files in this and all subfolder ####################################
######## no arguments
remove_gitignores() {
  find ./ -name ${GIT_IGNORE} -exec rm -f {} \;
}

######## Redefines the .gitignore file for binary tracking type ###################################
######## no arguments
set_gitignore_binary_type() {
  echo "*" > ${GIT_IGNORE}
  for file_name in "${FILES_REQUIRED_GIT_IGNORE_BIN_TYPE[@]}"; do
    echo "!${file_name}" >> ${GIT_IGNORE}
  done
}

######## Extends the .gitignore file for standard tracking type ###################################
######## no arguments
set_gitignore_standard_type() {
  if [ -f "${GIT_IGNORE}" ]; then
    echo "# Binaries added by git-metadata tool" >> ${GIT_IGNORE}
  else
    echo "# Binaries added by git-metadata tool" > ${GIT_IGNORE}
  fi
  echo "## Must be ignored" >> ${GIT_IGNORE}
  echo "${BINARY_COMMIT}" >> ${GIT_IGNORE}
  echo "## Example Binaries"
  for pattern in "${PATTERN_GIT_IGNORE_STANDARD_TYPE[@]}"; do
    if ! grep -qx "${pattern}" ${GIT_IGNORE}; then
      echo "${pattern}" >> ${GIT_IGNORE}
    fi
  done
}

######## Initializes metadata tracking of binaries. ###############################################
######## no arguments | exit
init() {
  if [ ! "$#" -eq 1 ]; then
    exit_wrong_argument "Invalid number of arguments: expected one, found $#."
  elif ! array_contains_element "$1" "${INIT_TYPE[@]}"; then
    exit_wrong_argument "Argument $1 is invalid, allowed are: ${INIT_TYPE[*]}"
  fi
  check_tools
  check_git
  if [ -f ${METADATA} ]; then
    exit_on_success "Found file ${METADATA}, tracking of binary metadata already initialized."
  fi
  if get_config_branch > /dev/null; then
    exit_unmet_requirements "Metadata config branch is already set up which means that this is the wrong branch or ${METADATA} was deleted."
  fi
  if has_a_commit && git_has_uncommitted_changes; then
    exit_unmet_requirements "Initializing git metadata tracking requires a clean git status."
  fi
  # use current branch for metadata tracking
  git config --file=${GIT_CONFIG} "${CONFIG_METADATA_BRANCH}" "$(get_current_branch)"
  if [ "$1" = "binary" ]; then
    ## remove gitignore in subfolders
    find ./ -name ${GIT_IGNORE} -exec rm -f {} \; || exit_command_fail "Failed to remove .gitignore files."
    set_gitignore_binary_type
    echo "Setup ${GIT_IGNORE} to ignore all files unless explicitly not-ignored."
  elif [ "$1" = "standard" ]; then
    set_gitignore_standard_type
    echo "${GIT_IGNORE} introduced/extended, all files/patterns which should not be tracked by git must be added to $GIT_IGNORE."
  fi
  git add ${GIT_IGNORE}
  git add ${GIT_CONFIG}
  git commit -m "Initialize metadata tracking of binaries for $1 tracking-type."
  header_metadata_file > ${METADATA}
  git add ${METADATA}
  exit_on_success "git metadata tracking of binaries successfully initialized."
}

###################################################################################################
######## Update ###################################################################################
###################################################################################################

######## Generates an update message for the git commit ###########################################
######## no arguments
generate_update_message() {
  echo "Metadata update $(($(get_commit_number "$(get_last_commit_metadata_local)") + 1))" || echo "Metadata update"
}

######## Sets the arguments used by 'git commit' ##################################################
set_commit_arguments() {
  if [ ! "$2" ]; then
    COMMIT_ARGS=("-m" "$1")
  else
    COMMIT_ARGS=("${@}")
  fi
}

######## Parsing the cli parameter for the update command #########################################
######## arguments: cli parameter, if none, a commit message is created
parse_cli_update_args() {
  if [ ! "$1" ]; then
    set_commit_arguments "$(generate_update_message)"
  else
    if [ "$2" ]; then
      if [ "$1" = "--force" ]; then
        FORCE=${TRUE}
        shift 1
      fi
      ## check if last argument is --force
      if [ "${*:$#}" = "--force" ]; then
        FORCE=${TRUE}
        set -- "${@:1:$#-1}"  ### this removes the last argument (shift 1 removes first arg)
      fi
      set_commit_arguments "${@}"
    else
      if [ "$1" = "--force" ]; then
        FORCE=${TRUE}
        set_commit_arguments "$(generate_update_message)"
      else
        set_commit_arguments "${@}"
      fi
    fi
  fi
}

######## Checks if update of ${METADATA} file is possible. ########################################
######## no arguments | exit with error if update not possible
check_update() {
  if [ ! -f ${BINARY_COMMIT} ]; then
    echo "Missing file ${BINARY_COMMIT}, do a '--force' update."
  else
    set_LOCAL_BIN_SHA
    set_LAST_METADATA_SHA
    if [ ! "$LOCAL_BIN_SHA" = "$LAST_METADATA_SHA" ]; then
      exit_unmet_requirements "Can not update because git commit of ${METADATA}: ${LAST_METADATA_SHA} differs from last update commit: ${LOCAL_BIN_SHA}."
    fi
    if has_remote_git; then
      for f in $(get_remote_git_names); do
        local compare_result_f
        compare_result_f="$(get_comparison_status "$LAST_METADATA_SHA" "$(get_last_commit_metadata_remote "$f")")" || exit_internal_error "Internal error, could not compare local and remote git $f due to: $compare_result_f"
        if [ "$compare_result_f" = "$CONSTANT_DIVERGENT_TO" ] || [ "$compare_result_f" = "$CONSTANT_BEHIND_OF" ]; then
          exit_unmet_requirements "Prevent simple update because local metadata $compare_result_f remote git $f."
        fi
      done
    fi
  fi
}

######## Updates file ${BINARY_COMMIT} with latest git commit sha #################################
######## no arguments
update_BINARY_COMMIT_file() {
   get_last_commit_metadata_local > ${BINARY_COMMIT} || exit_command_fail "Could not write latest commit sha into ${BINARY_COMMIT} file."
}

######## Updates the metadata file ################################################################
######## arguments optional | exit
update() {
  check_basics_metadata
  parse_cli_update_args "${@}"
  if [ ! "$FORCE" ]; then
    check_update
  fi

  get_metadata_of_local_binaries > ${METADATA} || exit_command_fail "No commit, update of ${METADATA} file is incomplete."
  # notice if metadata does not change, git add has no effect
  git add ${METADATA}
  if git_has_uncommitted_changes; then
    git commit "${COMMIT_ARGS[@]}" || exit_command_fail "Committing of metadata changes failed."
    update_BINARY_COMMIT_file
    exit_on_success "Metadata have been updated successfully."
  else
    if [ ! -f ${BINARY_COMMIT} ] || [ "$FORCE" = "$TRUE" ]; then
      echo "Set up file ${BINARY_COMMIT} with latest metadata commit."
      update_BINARY_COMMIT_file
    fi
    exit_on_success "Nothing to commit, binary metadata are up to date."
  fi
}

###################################################################################################
######## Status ###################################################################################
###################################################################################################

######## Prints the status message for provided arguments #########################################
######## three arguments: first and third are repo-names, the second is the compare msg
print_status() {
  local color_first_arg color_second_arg
  case "$2" in
    "${CONSTANT_SAME_AS}") color_first_arg=""; color_second_arg=""; ;;
    "${CONSTANT_AHEAD_OF}") color_first_arg=${GREEN}; color_second_arg=${RED}; ;;
    "${CONSTANT_BEHIND_OF}") color_first_arg=${RED}; color_second_arg=${GREEN}; ;;
    "${CONSTANT_DIVERGENT_TO}") color_first_arg=${RED}; color_second_arg=${RED}; ;;
    "${FAILED_RESULT}") color_first_arg=${PINK}; color_second_arg=${PINK} ;;
    *) exit_internal_error "Internal error: $2 is not a valid comparison result."
  esac
  echo -e "${CONSTANT_SPACE}${color_first_arg}$1${COLOR_OFF}|$2|${color_second_arg}$3${COLOR_OFF}"
}

######## Prints the comparison of the commit-sha for the different repositories ###################
######## no arguments
status_commits() {
  local name_print_status_local_git name_print_status_local_binary name_print_status_remote_binary_r remote_bin_sha_r
  name_print_status_local_git="$(get_name_metadata_commit)"
  name_print_status_local_binary="$(get_name_commit_sha)"
  if has_remote_git; then
    for f in $(get_remote_git_names); do
      local last_metadata_sha_f
      last_metadata_sha_f=$(get_last_commit_metadata_remote "$f") || exit_command_fail "Failed to retrieve the latest commit sha of metadata file on git-remote $f."
      print_status "$(get_name_metadata_commit "$f")" "$(get_comparison_status "${last_metadata_sha_f}" "${LAST_METADATA_SHA}")" "${name_print_status_local_git}"
    done
  fi
  print_status "${name_print_status_local_git}" "$(get_comparison_status "${LAST_METADATA_SHA}" "${LOCAL_BIN_SHA}")" "${name_print_status_local_binary}"
  for r in "${STATUS_CHECK_REMOTE_BINARY[@]}"; do
    name_print_status_remote_binary_r="$(get_name_commit_sha "${r}")"
    remote_bin_sha_r="$(get_remote_bin_sha_by_name "$r")"
    if is_in_local_git_history "$remote_bin_sha_r"; then
      print_status "${name_print_status_local_binary}" "$(get_comparison_status "${LOCAL_BIN_SHA}" "${remote_bin_sha_r}")" "${name_print_status_remote_binary_r}"
      print_status "${name_print_status_remote_binary_r}" "$(get_comparison_status "${remote_bin_sha_r}" "${LAST_METADATA_SHA}")" "${name_print_status_local_git}"
    else
      print_status "${name_print_status_remote_binary_r}" "$FAILED_RESULT" "since commit sha is not in local git history"
    fi
  done
}

######## Retrieves the status of tracked metadata vs current metadata of binaries #################
######## optional argument: remote name or local | exit
status() {
  check_basics_metadata
  declare -a STATUS_CHECK_REMOTE_BINARY=()

  set_LAST_METADATA_SHA
  set_LOCAL_BIN_SHA
  if [ "$2" ]; then
    exit_wrong_argument "The status command accepts at most one argument."
  fi
  if [ "$1" = "--all" ]; then
    if has_remote_binary; then
      check_rsync_install
      readarray -t STATUS_CHECK_REMOTE_BINARY < <(get_remote_binary_names)
    fi
  elif [ "$1" ] && [ ! "$1" = "$(get_name_commit_sha)" ] && [ ! "$1" = "local" ]; then
    check_and_set_remote "$1"
    STATUS_CHECK_REMOTE_BINARY=("${BIN_REMOTE_NAME}")
  fi

  check_serialization_version "$LOCAL_BIN_SHA"
  diff_metadata "$LOCAL_BIN_SHA" > /dev/null
  case "$?" in
    0) echo "Metadata of local binaries did not change since last update." ;;
    1) echo -e "Metadata of local binaries ${RED}have changed since last update${COLOR_OFF}. Run 'git metadata diff' to show changes." ;;
    21) echo -e "${RED}Unable to determine status if local files changed since commit sha $LOCAL_BIN_SHA in file $BINARY_COMMIT is not in local git history!${COLOR_OFF}" ;;
    *) echo -e "${RED}Unable to determine status if local files changed since the diff command failed for unknown reason.${COLOR_OFF}"
  esac
  echo "Comparison of latest commits of ${METADATA} file on git-repos and latest update commits of binaries:"
  status_commits | column -t -s'|'
  exit 0
}

###################################################################################################
######## Diff #####################################################################################
###################################################################################################

######## Shows difference of current local files in comparison to committed metadata ##############
######## argument $1: name of commit-sha for $1
######## argument $2: commit sha of metadata to be diffed against local metadata
show_difference_to_local_files() {
  if [ ! "$#" -eq 2 ]; then
    exit_internal_error "Internal error: expected two arguments but received $#."
  fi
  if [ "${CHANGED_ONLY}" ]; then
    get_changed_files "$2"
    case "$?" in
      0|1) exit 0 ;;
      21) exit_unknown_commit "$1 has commit sha $2 which is not in local git history." ;;
      *) exit_command_fail "Unable to determine the changed files: $?"
    esac
  fi
  if [ ! "${CLASSIC}" ]; then
    DIFF_FORMAT=(--new-line-format=$'\e[0;32mf %L\e[0m' --old-line-format=$'\e[0;31mc %L\e[0m' --unchanged-line-format='')
    OLD_LINE_CHARACTER='c'
    NEW_LINE_CHARACTER='f'
  fi
  diff_metadata "$2"
  case "$?" in
    0) echo "Metadata of local binaries coincide with metadata for $1." ;;
    1) echo -e "Metadata of local binaries are different from metadata at $1: ${RED}'${OLD_LINE_CHARACTER}' $1${COLOR_OFF}, ${GREEN}'${NEW_LINE_CHARACTER}' local file${COLOR_OFF}, File version differs if appears twice in both colors." ;;
    21) exit_unknown_commit "Unable to diff because commit sha of '$1' is '$2' which is not in local git history." ;;
    *) exit_command_fail "Diff failed for unknown reason: $?"
  esac
  check_serialization_version "$2"  # check after diff since information may be lost when lot of files
}

######## Shows difference between metadata for two commits provided in arguments ##################
######## argument $1, $3: name of commit-sha for $2, $4
######## argument $2, $4: commit sha of metadata to be diffed
show_difference_between_commits() {
  if [ ! "$#" -eq 4 ]; then
    exit_internal_error "Internal error: expected 4 arguments but received $#."
  fi
  if [ "$2" = "$4" ]; then
    exit_on_success "Metadata for $1 and $3 are on the same commit."
  fi
  if [ "${CHANGED_ONLY}" ]; then
    get_changed_files "${@}"
    case "$?" in
      0|1) exit 0 ;;
      21|22) exit_unknown_commit "Unable to determine changed files, $1 or $3 has a commit sha in file $BINARY_COMMIT which is not in local git history." ;;
      *) exit_command_fail "Could not determine the change only files: $?"
    esac
  fi
  if [ ! "${CLASSIC}" ]; then
    DIFF_FORMAT=(--new-line-format=$'\e[0;32m+ %L\e[0m' --old-line-format=$'\e[0;31m- %L\e[0m' --unchanged-line-format='')
    OLD_LINE_CHARACTER='-'
    NEW_LINE_CHARACTER='+'
  fi
  diff_metadata "$2" "$4"
  case "$?" in
    0) echo "Metadata for $1 and $3 coincide." ;;
    1) echo -e "Metadata for $1 and $3 are different: ${RED}'${OLD_LINE_CHARACTER}' $1${COLOR_OFF}, ${GREEN}'${NEW_LINE_CHARACTER}' $3${COLOR_OFF}, File version differs if appears twice in both colors." ;;
    21) exit_unknown_commit "Unable to diff because commit sha of '$1' is '$2' which is not in local git history." ;;
    22) exit_unknown_commit "Unable to diff because commit sha of '$3' is '$4' which is not in local git history." ;;
    *) exit_command_fail "Diff failed for unknown reason: $?"
  esac
}

######## Shows the extended diff if two commits are divergent, run diffs against common ancestor ##
######## arguments $1,$2 mandatory name/commit, likewise $3,$4 are optional
show_merge_based_diff() {
  local name="merge-base" merge_base
  if [ "$1" = "" ]; then
    exit_wrong_argument "Using --merge option requires a commit argument."
  elif [ "$#" -eq 2 ]; then
    set_LOCAL_BIN_SHA;
    merge_base=$(get_common_ancestor "$2" "$LOCAL_BIN_SHA")
    if [ "$2" = "$merge_base" ]; then
      echo "Not in a divergent situation with $1, print standard diff only!"
      show_difference_to_local_files "${@}"
    elif [ "$merge_base" = "$FAILED_RESULT" ]; then
      exit_unknown_commit "Diff not possible, unable to retrieve the common merge base of $2 and $LOCAL_BIN_SHA."
    else
      echo "Metadata diff of common ancestor $merge_base and $1:"
      show_difference_between_commits "$name" "$merge_base" "$1" "$2"
      echo ""
      echo "Metadata changes of local binaries since common ancestor $merge_base":
      show_difference_to_local_files "$name" "$merge_base"
    fi
  elif [ "$#" -eq 4 ]; then
    merge_base=$(get_common_ancestor "$2" "$4")
    if [ "$merge_base" = "$2" ] || [ "$merge_base" = "$4" ]; then
      echo "Commits for $1 and $3 are not divergent, print standard diff only!"
      show_difference_between_commits "${@}"
    elif [ "$merge_base" = "$FAILED_RESULT" ]; then
      exit_unknown_commit "Diff not possible, unable to retrieve the common merge base of $2 and $4."
    else
      echo "Metadata diff of common ancestor $merge_base and $1:"
      show_difference_between_commits "$name" "$merge_base" "$1" "$2"
      echo ""
      echo "Metadata diff of common ancestor $merge_base and $3:"
      show_difference_between_commits "$name" "$merge_base" "$3" "$4"
    fi
  else
    exit_internal_error "Internal error: unexpected number of arguments!"
  fi
}

######## Helper function to return remote commit sha or exit with error ###########################
######## argument: remote binary or remote git repo as in git config | exit with error if not remote
handle_remote_or_exit_error() {
  if is_binary_remote "$1"; then
    get_remote_bin_sha_by_name "$1" || exit_command_fail "Failed to retrieve a valid bin-sha for binary remote '$1'."
  elif is_git_remote "$1"; then
    get_last_commit_metadata_remote "$1" || exit_command_fail "Unable to retrieve the last metadata commit for remote git '$1'."
  else
    exit_wrong_argument "$1 is neither a binary nor a git remote repository."
  fi
}

######## Parsing the non-option arguments #########################################################
######## single mandatory argument: commit-sha or name-pointer to a commit-sha
parse_main_diff_argument() {
  if [ ! "$#" -eq 1 ] || [ "$1" = "" ]; then
    exit_wrong_argument "Invalid number of arguments or first argument is empty!"
  fi
  local arg="$1"
  case "$arg" in
    "$(get_complete_commit_sha_or_fail "$arg")") echo "$arg" ;;
    "$(get_name_metadata_commit)") get_last_commit_metadata_local ;;   # @local-git
    "$(get_name_commit_sha)") get_complete_LOCAL_BIN_SHA ;;           # @local-bin
    "$(get_name_metadata_commit "${arg#*@}")") handle_remote_or_exit_error "${arg#*@}" ;;           # @remote-git
    "$(get_name_commit_sha "${arg#*@}")") handle_remote_or_exit_error "${arg#*@}" ;;
    *) handle_remote_or_exit_error "$arg" ;;
  esac
}

######## Parsing the arguments for the diff command ###############################################
######## arguments: options --classic, --changed, --merge, commit(s) or name-pointer(s) to commit
parse_diff_cli() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      "--classic") CLASSIC=${TRUE}; shift 1; ;;
      "--changed") CHANGED_ONLY=${TRUE}; shift 1; ;;
      "--merge-base") MERGE_DIFF=${TRUE}; shift 1; ;;
      *) COMPARE_ARGS=("${COMPARE_ARGS[@]}" "$1" "$(parse_main_diff_argument "$1")") || exit_wrong_argument "Invalid argument: $1 is neither a valid option nor a valid identifier for a commit-sha or pointer to it!";  shift 1; ;;
    esac
  done
  if [ "$CHANGED_ONLY" = "${TRUE}" ]; then
    if [ "$CLASSIC" = "${TRUE}" ] || [ "$MERGE_DIFF" = "${TRUE}" ]; then
      exit_wrong_argument "If argument --changed is present neither '--classic' nor '--merge-base' can be provided."
    fi
  fi
}

######## Diff #####################################################################################
######## arguments: options --classic or --changed, commit(s) or name-pointer(s) to commit | exit
difference() {
  check_basics_metadata
  declare -a COMPARE_ARGS
  OLD_LINE_CHARACTER='<'
  NEW_LINE_CHARACTER='>'
  parse_diff_cli "${@}"
  if [ "$MERGE_DIFF" = "${TRUE}" ]; then
    show_merge_based_diff "${COMPARE_ARGS[@]}"
  else
    case "${#COMPARE_ARGS[@]}" in
      0) set_LOCAL_BIN_SHA; show_difference_to_local_files "$(get_name_commit_sha)" "$LOCAL_BIN_SHA"; ;;
      2) show_difference_to_local_files "${COMPARE_ARGS[@]}" ;;
      4) show_difference_between_commits "${COMPARE_ARGS[@]}" ;;
      *) exit_internal_error "Internal error: array of unexpected size!"
    esac
  fi
  exit 0
}

###################################################################################################
######## Pull, Force Pull and Merge ###############################################################
######## consumes cli args of pull command: remote-binary as in git config, optional --force ######
###################################################################################################

######## Rsync, remote is source and local is target, deletes local file if remote not present ####
######## no arguments | requires ${BIN_REMOTE_URL}
rsync_local() {
  get_rsync_ignores | rsync --numeric-ids --progress -avz --delete --exclude-from=- "${BIN_REMOTE_URL}/" ./ || exit_command_fail "Pull is incomplete, rsync failed!"
  exit_on_success "Successfully updated local binary repository."
}

######## Minimal requirements for a pull or merge #################################################
######## mandatory argument: remote name as in the git config
common_pull_requirements() {
  check_basics_metadata
  parse_cli_parameter_sync_command "${@}"

  set_LAST_METADATA_SHA
  set_REMOTE_BIN_SHA
  check_serialization_version "$REMOTE_BIN_SHA"
  if [ ! "$REMOTE_BIN_SHA" = "$LAST_METADATA_SHA" ]; then
    exit_unmet_requirements "Pull failed because remote commit-sha '$REMOTE_BIN_SHA' is different than last metadata commit '$LAST_METADATA_SHA' in local git history."
  fi
}

######## Simple pull, requires no changes locally, remote in git history and local behind remote ##
######## consumes cli args of push command: remote-binary as in git config, optional --force
pull() {
  common_pull_requirements "${@}"

  if [ ! "$FORCE" ]; then
    set_LOCAL_BIN_SHA
    exit_error_if_uncommitted_changes
    exit_success_if_remote_equals_local

    local comparison
    comparison=$(get_comparison_status "${LOCAL_BIN_SHA}" "${REMOTE_BIN_SHA}") || exit_command_fail "Unable to compare remote and local: $comparison"
    # since remote != local, local must be behind remote for a pull
    if [ ! "${comparison}" = "${CONSTANT_BEHIND_OF}" ]; then
      exit_unmet_requirements "Simple pull failed because local-binary $comparison remote-binary ${BIN_REMOTE_NAME}."
    fi
  fi

  rsync_local
}

######## Merge ####################################################################################
######## consumes cli args of push command: remote-binary as in git config, optional --force
merge() {
  common_pull_requirements "${@}"
  if [ ! "$FORCE" ]; then
    # no need to check exit code of get_changed_files, since previous method already exits with error if REMOTE_BIN_SHA is unknown.
    if ! get_changed_files "${REMOTE_BIN_SHA}"; then
      exit_unmet_requirements "Failed to merge. The above files exist local and at remote ${BIN_REMOTE_NAME} in different version."
    fi
  fi
  get_rsync_ignores | rsync --numeric-ids --progress -auvz --exclude-from=- "${BIN_REMOTE_URL}/" ./ || exit_command_fail "Merge is incomplete, rsync failed!"
  exit_on_success "Successfully merged remote and local repository."
}

###################################################################################################
######## Push action ##############################################################################
######## consumes cli args of push command: remote-binary as in git config, optional --force ######
###################################################################################################

######## Rsync, local is source and remote is target, deletes remote files if local not present ###
######## no arguments | requires variable ${BIN_REMOTE_URL}
rsync_remote() {
  get_rsync_ignores | rsync --numeric-ids --progress -avz --delete --exclude-from=- ./ "${BIN_REMOTE_URL}" || exit_command_fail "Push to remote is incomplete, rsync operation failed."
  exit_on_success "Successfully updated remote binary repository."
}

######## Minimal requirements for a push ##########################################################
######## consumes cli args of push command: remote-binary as in git config, optional --force
push_requirements() {
  check_basics_metadata
  parse_cli_parameter_sync_command "${@}"

  set_LAST_METADATA_SHA
  set_LOCAL_BIN_SHA
  check_serialization_version "$LOCAL_BIN_SHA"
  exit_error_if_uncommitted_changes
  if [ ! "$LOCAL_BIN_SHA" = "$LAST_METADATA_SHA" ]; then
    exit_unmet_requirements "Push failed, binary commit-sha '$LOCAL_BIN_SHA' is different than last metadata commit '$LAST_METADATA_SHA' in git history."
  fi
}

######## Push action, requires no changes locally, if not forced, remote must be ahead of local ###
######## consumes cli args of push command: remote-binary as in git config, optional --force
push() {
  push_requirements "${@}"

  if [ ! "$FORCE" ]; then
    set_REMOTE_BIN_SHA
    exit_success_if_remote_equals_local
    local comparison
    comparison=$(get_comparison_status "${REMOTE_BIN_SHA}" "${LOCAL_BIN_SHA}") || exit_command_fail "Unable to compare remote and local: $comparison"
    # since remote != local, remote must be behind local for a push
    if [ ! "${comparison}" = "${CONSTANT_BEHIND_OF}" ]; then
      exit_unmet_requirements "Push failed, remote-binary ${BIN_REMOTE_NAME} ${comparison} local-binary."
    fi
  fi

  rsync_remote
}

###################################################################################################
######## Shows additional information #############################################################
######## consumes cli args of show command: pointer, config, remote-binary ########################
###################################################################################################

######## Prints information about the name-pointers to commits ####################################
######## no arguments
print_commit_pointer_info() {
  echo "$(get_name_commit_sha)|represents commit-sha in local file ${BINARY_COMMIT} which holds commit of the latest local metadata update."
  if has_remote_binary; then
    for f in $(get_remote_binary_names); do
      echo "$(get_name_commit_sha "$f")|represents commit-sha in file ${BINARY_COMMIT} at remote $(get_binary_remote_url "$f")."
    done
  else
    echo "$(get_name_commit_sha "<remote-bin>")|represents commit-sha in file ${BINARY_COMMIT} at remote repository <remote-binary.url>."
  fi
  echo "$(get_name_metadata_commit)|current head of metadata for local git repository."
  if has_remote_git; then
    for g in $(get_remote_git_names); do
      echo "$(get_name_metadata_commit "$g")|current head of metadata for remote git repository $g."
    done
  else
    echo "$(get_name_metadata_commit "<remote-git>")|current head of metadata for remote git repository defined in config."
  fi
}

######## Prints information about available remote binaries defined in git config #################
######## no arguments
print_remote_binaries() {
  if has_remote_binary; then
    for f in $(get_remote_binary_names); do
      echo "$f|$(get_binary_remote_url "$f")"
    done
  else
    echo "There is no remote binary defined in git config."
  fi
}

######## Prints information about available remote binaries defined in git config #################
######## no arguments
print_config_values() {
  echo "Branch used by git-metadata|$(get_config_branch)"
  echo "Repository type|$(get_repository_type)"
  if has_remote_git; then
    echo "Remote git repository name(s)|$(get_remote_git_names | xargs | sed -e 's/ /, /g')"
  else
    echo "There is no setup for a remote git server."
  fi
  if has_remote_binary; then
    echo "Remote binary name(s)|$(get_remote_binary_names | xargs | sed -e 's/ /, /g')"
  else
    echo "There is no remote binary defined in git config."
  fi
}

###################################################################################################
######## Shows additional information #############################################################
show() {
  if [ ! "$#" -eq 1 ]; then
    exit_wrong_argument "Invalid number of arguments: expected one, found $#."
  fi
  case "$1" in
    "pointer") print_commit_pointer_info | column -t -s"|" ;;
    "remote-binary") print_remote_binaries | column -t -s"|" ;;
    "config") print_config_values | column -t -s"|" ;;
    *) exit_wrong_argument "$1 is not a valid argument for the show command."
  esac
  exit 0
}

###################################################################################################
######## Prints the version information for this tool #############################################
######## optional arguments $1, $2: --short and/or --serialization | exit
###################################################################################################
print_version_info() {
  local short_arg="", serialization_arg="", version
  while [ "$#" -gt 0 ]; do
    case "$1" in
      "--short") short_arg=${TRUE}; shift 1; ;;
      "--serialization") serialization_arg=${TRUE}; shift 1; ;;
      *) exit_wrong_argument "Invalid argument for version retrieval: $1"
    esac
  done
  if [ "$serialization_arg" = "$TRUE" ]; then
    if [ "$short_arg" = "$TRUE" ]; then
      exit_on_success "$METADATA_SERIALIZATION_VERSION"
    else
      exit_on_success "git-metadata serialization: $METADATA_SERIALIZATION_VERSION"
    fi
  else
    version="$(get_version)" || exit_command_fail "Failed to retrieve the version information."
    if [ "$short_arg" = "$TRUE" ]; then
      exit_on_success "$version"
    else
      exit_on_success "git-metadata version: $version"
    fi
  fi
}

###################################################################################################
######## Bash Completion ##########################################################################
###################################################################################################

######## Completion for diff command ##############################################################
diff_completion_arguments() {
  echo "--classic"
  echo "--changed"
  echo "--merge-base"
  get_name_commit_sha
  get_name_metadata_commit
  if has_remote_binary; then
    get_remote_binary_names
  fi
  if has_remote_git; then
    get_remote_git_names
  fi
}

###################################################################################################
######## Retrieves the POSSIBLE_COMPLETION if WORD $1 is empty or partial match of possibilities
get_completions_if_empty_or_partial_match() {
  if [ "$1" = "" ] && [ ${#POSSIBLE_COMPLETION[@]} -gt 0 ]; then
    echo "${POSSIBLE_COMPLETION[@]}"
  elif [ "$2" = "" ]; then
    local partial=()
    for s in "${POSSIBLE_COMPLETION[@]}"; do
      if [[ $s == $1* ]] && [[ ! "$s" == "$1" ]]; then
        partial+=("$s")
      fi
    done
    if [ ${#partial[@]} -gt 0 ]; then
      echo "${partial[@]}"
    fi
  fi
}

###################################################################################################
####### Shifts valid arguments and calls previous method
get_completions_after_valid_shifts() {
  while array_contains_element "$1" "${POSSIBLE_COMPLETION[@]}"; do
    shift 1
  done
  get_completions_if_empty_or_partial_match "${@}"
}

###################################################################################################
######## Prints --force completion option if last argument starts with --f and is not --force
force_completion() {
  local arg_x=("${@}")
  if [ "$#" -ge 1 ] && [ ! "${arg_x[-1]}" = "${arg_x[-1]#--f}" ] && ! array_contains_element "--force" "${arg_x[@]}"; then
    echo "--force"
  fi
}

###################################################################################################
######## Returns possible bash completions depending on the current command
commands() {
  declare -a POSSIBLE_COMPLETION=()
  case "$1" in
    "help") exit 0 ;;
    "init")
      shift 1
      POSSIBLE_COMPLETION=("${INIT_TYPE[@]}")
      get_completions_if_empty_or_partial_match "${@}"
      exit 0 ;;
    "update")
      shift 1
      force_completion "${@}"
      exit 0 ;;
    "status")
      shift 1
      if has_remote_binary; then
        readarray -t POSSIBLE_COMPLETION < <(get_remote_binary_names)
        POSSIBLE_COMPLETION+=("--all")
        get_completions_if_empty_or_partial_match "${@}"
      fi
      exit 0 ;;
    "pull" | "push" | "merge")
      shift 1
      force_completion "${@}"
      if has_remote_binary; then
        readarray -t POSSIBLE_COMPLETION < <(get_remote_binary_names)
        if [ "$1" = "--force" ]; then
          shift 1
          get_completions_if_empty_or_partial_match "${@}"
        else
          get_completions_if_empty_or_partial_match "${@}"
        fi
      fi
      exit 0 ;;
    "show")
      shift 1
      POSSIBLE_COMPLETION=("config" "pointer" "remote-binary")
      get_completions_if_empty_or_partial_match "${@}"
      exit 0 ;;
    "version")
      shift 1
      POSSIBLE_COMPLETION=("--serialization" "--short")
      get_completions_after_valid_shifts "${@}"
      exit 0 ;;
    "diff")
      shift 1
      readarray -t POSSIBLE_COMPLETION < <(diff_completion_arguments)
      get_completions_after_valid_shifts "${@}"
      exit 0 ;;
    *)
      POSSIBLE_COMPLETION=("diff" "help" "init" "merge" "pull" "push" "show" "status" "update" "version")
      get_completions_if_empty_or_partial_match "${@}"
      exit 0
  esac
}

###################################################################################################
######## Main function ############################################################################
###################################################################################################
main() {
  case "$1" in
    "arguments") shift 3; commands "${@}" ;;
    "diff") shift 1; difference "${@}" ;;
    "help") shift 1; man git-metadata; exit 0 ;;
    "init") shift 1; init "${@}" ;;
    "merge") shift 1; merge "${@}" ;;
    "pull") shift 1; pull "${@}" ;;
    "push") shift 1; push "${@}" ;;
    "show") shift 1; show "${@}" ;;
    "status") shift 1; status "${@}" ;;
    "update") shift 1; update "${@}" ;;
    "version") shift 1; print_version_info "${@}" ;;
    "--version") print_version_info ;;
    "--help") man git-metadata; exit 0 ;;
    *) exit_wrong_argument "'$1' is not a valid git-metadata command, please check 'git metadata help'."
  esac
  exit_internal_error "Internal error, missing at least one clean exit!"
}

###################################################################################################
main "${@}"
