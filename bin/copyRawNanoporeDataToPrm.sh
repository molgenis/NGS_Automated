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
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename "${0}")"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"

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
Script to copy (sync) data from a raw data from prm to tmp.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g [group]
		Group for which to process data.
	-r [remote_server]
		address of the remote_server
		e.g. 145.39.79.24
	-l [level]
		Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 4 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg       for the group specified with -g
		2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
		3. <source_host>.cfg for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
		4. sharedConfig.cfg  for all groups and all servers.
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
while getopts ":g:l:r:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		r)
			remote_machine="${OPTARG}"
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
			;;
	esac
done

#
# Check commandline options.
#
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

if [[ -z "${remote_machine:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a remote_machine with -r.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
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
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group per combination of ${samplesheetsServerLocation} and ${samplesheetsLocation}.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
#
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs ..."

#
# Use multiplexing to reduce the amount of SSH connections created
# when rsyncing using the group's data manager account.
# 
#  1. Become the "${DATA_MANAGER} user who will rsync the data to prm and 
#  2. Add to ~/.ssh/config:
#		ControlMaster auto
#		ControlPath ~/.ssh/tmp/%h_%p_%r
#		ControlPersist 5m
#  3. Create ~/.ssh/tmp dir:
#		mkdir -p -m 700 ~/.ssh/tmp
#  4. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#		chmod -R go-rwx ~/.ssh
#

REMOTE_USER="grid"
#REMOTE_MACHINE="145.39.79.24"
PRM_SAMPLESHEET_DIR="${PRM_ROOT_DIR}/nanopore/Samplesheets"
SOURCE_DIR="/data/Diagnostiek/"
SOURCE_LOGS_DIR="/data/logs/Diagnostiek/"
DESTINATION_DIR="${PRM_ROOT_DIR}/rawdata/nanopore/"

#
# Loop over their analysis ("run") sub dirs and check if there are any we need to rsync.
#
declare -a runs

# Parse nanopore folder.
#
# shellcheck disable=SC2029
readarray -t runs < <(ssh "${REMOTE_USER}"@"${remote_machine}" "find \"${SOURCE_DIR}\" -maxdepth 1 -mindepth 1 -type d")

for run in "${runs[@]}"
do
	#
	# Process this run
	#
	runName="$(basename "${run}")"
	controlFileBase="${PRM_ROOT_DIR}/logs/${runName}/${runName}"
	export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
	# shellcheck disable=SC2174
	mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${runName}/"
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed run ${runName}."
		continue
	else

		#
		# Determine whether an rsync is required for this run, which is the case when
		# raw data production has finished successfully and this copy script has not.
		#
		if rsync "${REMOTE_USER}@${remote_machine}:${SOURCE_DIR}/${runName}/${runName}/*/sample_sheet_*.csv" 2>/dev/null
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${REMOTE_USER}@${remote_machine}:${SOURCE_DIR}/${runName}/${runName}/*/sample_sheet_"*".csv present."
			finished="true"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${REMOTE_USER}@${remote_machine}:${SOURCE_DIR}/${runName}/${runName}/*/sample_sheet_*.csv absent."
			finished="false"
		fi

		if rsync "${REMOTE_USER}@${remote_machine}:${SOURCE_LOGS_DIR}/${runName}/calculateMd5s.finished" 2>/dev/null
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${REMOTE_USER}@${remote_machine}:${SOURCE_LOGS_DIR}/${runName}/calculateMd5s.finished present."
			md5finished="true"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${REMOTE_USER}@${remote_machine}:${SOURCE_LOGS_DIR}/${runName}/calculateMd5s.finished absent."
			md5finished="false"
		fi

		if [[ -e "${PRM_SAMPLESHEET_DIR}/${runName}.csv" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_SAMPLESHEET_DIR}/${runName}.csv present."
			samplesheetPresent="true"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_SAMPLESHEET_DIR}/${runName}.csv absent."
			samplesheetPresent="false"
		fi
		
		

		if [[ "${finished}" == "true" && "${samplesheetPresent}" == "true" && "${md5finished}" == "true" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing everything from ${runName}"
			touch "${JOB_CONTROLE_FILE_BASE}.started"

			/usr/bin/rsync -vrltD \
				--log-file="${JOB_CONTROLE_FILE_BASE}.log" \
				--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
				--omit-dir-times \
				--omit-link-times \
				--exclude '*_fail' \
				--exclude 'bam_*' \
				"${REMOTE_USER}@${remote_machine}:${SOURCE_DIR}/${runName}" \
				"${DESTINATION_DIR}" \
				|| {
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync ${runName}"
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "from ${REMOTE_USER}@${remote_machine}:${SOURCE_DIR}/${runName}"
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "to ${DESTINATION_DIR}"
				mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				continue
				}
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully transferred the data from ${REMOTE_USER}@${remote_machine}:${SOURCE_DIR}/${runName} to ${diagnostic_server_location}:${DESTINATION_DIR}"
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencer is busy producing data, Samplesheet is missing or md5s are still being calculated: skipping ${runName}."
			continue
		fi

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully transferred all the data from ${runName} to ${DESTINATION_DIR}"
	rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
	mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}

	fi
done

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'

trap - EXIT
exit 0