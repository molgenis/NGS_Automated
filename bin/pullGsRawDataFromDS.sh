#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename ${0})"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname 2>/dev/null || echo 'no login name')"

#
##
### Quick first implementation without functions, config files, logging using log4bash, etc.
##
#

GROUP='umcg-genomescan'
SCR_LFS='scr01'
TMP_LFS='tmp06'
DATA_STAGING_HOST='cher-ami.hpc.rug.nl'

#
##
### Functions.
##
#

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	trap - EXIT
	exit 1
fi

#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#

lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."



#
# To make sure a *.finished file is not rsynced before a corresponding data upload is complete, we
# * first rsync everything, but with an exclude pattern for '*.finished' and
# * then do a second rsync for only '*.finished' files.
#
/usr/bin/rsync -vrltD \
	--log-file="/groups/${GROUP}/${TMP_LFS}/rsync-from-${DATA_STAGING_HOST%%.*}.log" \
	--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
	--omit-dir-times \
	--omit-link-times \
	--exclude='*.finished' \
	"${DATA_STAGING_HOST}:/groups/${GROUP}/${SCR_LFS}/*" \
	"/groups/${GROUP}/${TMP_LFS}/"

/usr/bin/rsync -vrltD \
	--log-file="/groups/${GROUP}/${TMP_LFS}/rsync-from-${DATA_STAGING_HOST%%.*}.log" \
	--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
	--omit-dir-times \
	--omit-link-times \
	--relative \
	"${DATA_STAGING_HOST}:/groups/${GROUP}/${SCR_LFS}/./*/*.finished" \
	"/groups/${GROUP}/${TMP_LFS}/"

#
# Cleanup old data if data transfer with rsync did not crash.
#
/usr/bin/ssh "${DATA_STAGING_HOST}" "/bin/find /groups/${GROUP}/${SCR_LFS}/ -mtime +14 -ignore_readdir_race -delete"