#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename "${0}")"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname 2>/dev/null || echo 'no login name')"

#
##
### Functions.
##
#

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
	# shellcheck source=lib/sharedFunctions.bash
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	trap - EXIT
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to pull data from a Data Staging (DS) server.

Usage:
	$(basename "${0}") OPTIONS
Options:
	-h	Show this help.
	-g	Group.
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:
	This script needs 4 config files, which must be located in ${CFG_DIR}:
	1. <group>.cfg       for the group specified with -g
	2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
	3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================
EOH
	trap - EXIT
	exit 0
}

#
##
### Main.
##
#

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
declare group=''
while getopts ":g:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels["${l4b_log_level}"]}"
			;;
		\?)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			;;
		:)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			;;
		*)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Unhandled option. Try $(basename "${0}") -h for help."
			;;	esac
done

#
# Check commandline options.
#
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	#"${HOME}/molgenis.cfg" Pull data from a DS server is currently not monitored using a Track & Trace Molgenis.
)

for configFile in "${configFiles[@]}"
do
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile} ..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		# Disable shellcheck code syntax checking for config files.
		# shellcheck source=/dev/null
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" "${?}" "Cannot source ${configFile}."
		# shellcheck source=/dev/null
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done

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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

#
# Define timestamp per day for a log file per day.
#
# We pull all data in one go and not per batch/experiment/sample/project,
# so we cannot create a log file per batch/experiment/sample/project to signal *.finished or *.failed.
# Using a single log file for this script, would mean we would only get an email notification for *.failed once,
# which would not get cleaned up / reset during the next attempt to rsync data.
# Therefore we define a JOB_CONTROLE_FILE_BASE per day, which will ensure we get notified once a day if something goes wrong.
#
# Note: this script will only create a *.failed using the log4Bash() function from lib/sharedFunctions.sh.
#
logTimeStamp="$(date "+%Y-%m-%d")"
logDir="${TMP_ROOT_DIR}/logs/${logTimeStamp}/"
# shellcheck disable=SC2174
mkdir -m 2770 -p "${logDir}"
touch "${logDir}"
export JOB_CONTROLE_FILE_BASE="${logDir}/${logTimeStamp}.${SCRIPT_NAME}"

#
# To make sure a *.finished file is not rsynced before a corresponding data upload is complete, we
# * first rsync everything, but with an exclude pattern for '*.finished' and
# * then do a second rsync for only '*.finished' files.
#
# shellcheck disable=SC2153
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pulling data from data staging server ${HOSTNAME_DATA_STAGING%%.*} using rsync to /groups/${GROUP}/${TMP_LFS}/ ..."
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "See ${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log for details ..."
declare -a gsProjectsSourceServer
# shellcheck disable=SC2029
readarray -t gsProjectsSourceServer< <(ssh "${HOSTNAME_DATA_STAGING}" "find \"/groups/${GROUP}/${SCR_LFS}/\" -mindepth 1 -maxdepth 1 -type d")
if [[ "${#gsProjectsSourceServer[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found at ${HOSTNAME_DATA_STAGING}:/groups/${GROUP}/${SCR_LFS}/"
else
	for gsProject in "${gsProjectsSourceServer[@]}"
	do
		gsProject="$(basename "${gsProject}")"
		if [ -e "/groups/${GROUP}/${TMP_LFS}/logs/${gsProject}/${gsProject}.processGsRawData.finished" ]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${gsProject} already processed, no need to transfer the data again."
		else
			#
			# Check if gsProject is supposed to be complete (*.finished present).
			#
			gsProjectUploadCompleted='false'
			# shellcheck disable=SC2029
			if ssh "${HOSTNAME_DATA_STAGING}" "find \"/groups/${GROUP}/${SCR_LFS}/${gsProject}/\" -mindepth 1 -maxdepth 1 -name '*.finished'"
			then
				gsProjectUploadCompleted='true'
			fi
			#
			# Rsync everything but the .finished file: may be imcompletely uploaded project,
			# but we already rsync everything we've got so far.
			#
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing everything but the .finished file for ${gsProject} ..."
			/usr/bin/rsync -vrltD \
				--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
				--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
				--omit-dir-times \
				--omit-link-times \
				--exclude='*.finished' \
				"${HOSTNAME_DATA_STAGING}:/groups/${GROUP}/${SCR_LFS}/${gsProject}" \
				"/groups/${GROUP}/${TMP_LFS}/"
			#
			# Rsync the .finished file last if the upload was complete.
			#
			if [[ "${gsProjectUploadCompleted}" == 'true' ]]
			then
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing only the .finished file for ${gsProject} ..."
				/usr/bin/rsync -vrltD \
					--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
					--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
					--omit-dir-times \
					--omit-link-times \
					"${HOSTNAME_DATA_STAGING}:/groups/${GROUP}/${SCR_LFS}/${gsProject}/*.finished" \
					"/groups/${GROUP}/${TMP_LFS}/${gsProject}/"
			else
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No .finished file for ${gsProject} present yet: nothing to sync."
			fi
		fi
	done
fi

if [[ "${CLEANUP}" == "false" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "this is a testgroup, data should not be removed after 14 days"
else
	#
	# Cleanup old data if data transfer with rsync finished successfully (and hence did not crash this script).
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting data older than 14 days from ${HOSTNAME_DATA_STAGING%%.*}:/groups/${GROUP}/${SCR_LFS}/ ..."
	# shellcheck disable=SC2029
	/usr/bin/ssh "${HOSTNAME_DATA_STAGING}" "/bin/find /groups/${GROUP}/${SCR_LFS}/ -mtime +14 -ignore_readdir_race -delete"
fi
#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0