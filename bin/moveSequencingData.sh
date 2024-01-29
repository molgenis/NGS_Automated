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
======================================================================================================================
Script to copy the sequencing data from dedicated sequencing storage (/groups/umcg-lab/${tmpDir}/sequencers_incoming/) to /groups/umcg-lab/${tmpDir}/sequencers when the sequencing is finished.

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

while getopts ":t:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		t)
			tmpDir="${OPTARG}"
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
if [[ -z "${tmpDir:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a tmpDir with -t'
fi
ATEAMBOTUSER="umcg-lab-ateambot"
#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Sequencer is writing to this location: ${SEQ_INCOMING_DIR}
#
SEQ_INCOMING_DIR="/groups/umcg-lab/${tmpDir}/sequencers_incoming/"
SEQ_DIR="/groups/umcg-lab/${tmpDir}/sequencers/"

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "find ${SEQ_INCOMING_DIR}/ -mindepth 1 -maxdepth 1 -type d -o -type l"
mapfile -t runs < <(find "${SEQ_INCOMING_DIR}/" -mindepth 1 -maxdepth 1 -type d -o -type l)

for i in "${runs[@]}"
do
	
	run=$(basename "${i}")
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking ${run} ..."
	moveSequencingDataJobControleFileBase="/groups/umcg-lab/${tmpDir}/logs/${run}/run01.moveSequencingData"
	
	export JOB_CONTROLE_FILE_BASE="${moveSequencingDataJobControleFileBase}"
	
	if [[ -f "${JOB_CONTROLE_FILE_BASE}.started" ]]
	then
		if [[ ! -f "${JOB_CONTROLE_FILE_BASE}.transferCompleted" ]]
		then			
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.started: Skipping ${run}, which is already getting processed."
			continue
		fi
	fi
	
	# shellcheck disable=SC2174
	mkdir -m 770 -p "/groups/umcg-lab/${tmpDir}/logs/${run}/"
	#
	# Check if the run has already completed.
	#
	if [[ -f "${SEQ_INCOMING_DIR}/${run}/CopyComplete.txt" ]]
	then
		if [[ ! -f "${JOB_CONTROLE_FILE_BASE}.transferCompleted" ]]
		then
			touch "${JOB_CONTROLE_FILE_BASE}.started"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencing run completed: ${run}. Copy data from ${SEQ_INCOMING_DIR} to ${SEQ_DIR}."

			if rsync -av --checksum --exclude="${SEQ_INCOMING_DIR}/${run}/RunCompletionStatus.xml" "${SEQ_INCOMING_DIR}/${run}"	"${SEQ_DIR}"
			then	
				rsync -av \
				"${SEQ_INCOMING_DIR}/${run}/RunCompletionStatus.xml" \
				"${SEQ_DIR}/${run}/"
		
				touch "${JOB_CONTROLE_FILE_BASE}.transferCompleted"
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to rsync ${SEQ_INCOMING_DIR}/${run}/."
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				exit 1
			fi
		fi
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencing run is not (yet) finished."
		continue
	fi

	if [[ -f "${JOB_CONTROLE_FILE_BASE}.transferCompleted" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Transfer completed for run ${run}."
		dateInSecRawData="$(date -d"$(rsync "${JOB_CONTROLE_FILE_BASE}.transferCompleted" | awk '{print $3}')" +%s)"
		dateInSecNow=$(date +%s)
		if [[ $(((dateInSecNow - dateInSecRawData) / 86400)) -gt 2 ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Transfer completed more than 2 days ago, ${run} will be removed from ${SEQ_INCOMING_DIR}"
			runDir="${SEQ_INCOMING_DIR}/${run}"
			rm -rf "${runDir:?}"
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Data removal on hold for ${run}: Transfer completed is less than 2 days ago"	
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to rsync ${SEQ_INCOMING_DIR}/${run}/."
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
	fi


done

trap - EXIT
exit 0
