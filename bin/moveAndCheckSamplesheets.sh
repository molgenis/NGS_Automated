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
	Script to check samplesheets and move to another location potentially on another server.

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
lockFile="${DAT_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${DAT_ROOT_DIR}/logs ..."

#
# Define timestamp per day for a log file per day.
#
# We move all data in one go and not per batch/experiment/sample/project,
# so we cannot create a log file per batch/experiment/sample/project to signal *.finished or *.failed.
# Using a single log file for this script, would mean we would only get an email notification for *.failed once,
# which would not get cleaned up / reset during the next attempt to rsync data.
# Therefore we define a JOB_CONTROLE_FILE_BASE per day, which will ensure we get notified once a day if something goes wrong.
#


samplesheetsSource="${DAT_ROOT_DIR}/samplesheets/new/"
#
# Find samplesheets.
#
readarray -t samplesheets < <(find "${samplesheetsSource}" -maxdepth 1 -mindepth 1 -type f -name "*.${SAMPLESHEET_EXT}")
if [[ "${#samplesheets[@]}" -eq '0' ]]
then
#	logTimeStamp="$(date "+%Y-%m-%d")"
#	logDir="${DAT_ROOT_DIR}/logs/${logTimeStamp}/"
	# shellcheck disable=SC2174
#	mkdir -m 2770 -p "${logDir}"
#	touch "${logDir}"
#	export JOB_CONTROLE_FILE_BASE="${logDir}/${logTimeStamp}.${SCRIPT_NAME}"
#	printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No samplesheets found in ${samplesheetsSource}."
#	mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	trap - EXIT
	exit 0
fi

for samplesheet in "${samplesheets[@]}"
do
	sampleSheetName=$(basename ${samplesheet%%.*})
	logDir="${DAT_ROOT_DIR}/logs/${sampleSheetName}/"
	# shellcheck disable=SC2174
	mkdir -m 2770 -p "${logDir}"
	touch "${logDir}"
	export JOB_CONTROLE_FILE_BASE="${logDir}/${sampleSheetName}.${SCRIPT_NAME}"
	printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()

	IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${samplesheet}")"
	
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	
	if [[ -n "${_sampleSheetColumnOffsets["SentrixBarcode_A"]+isset}" ]] 
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a GAP samplesheet, there is no samplesheetCheck at this moment"
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a NGS samplesheet, lets check if the samplesheet is correct"
		cp "${samplesheet}"{,.converted}
	
		#
		# Make sure
		#  1. The last line ends with a line end character.
		#  2. We have the right line end character: convert any carriage return (\r) to newline (\n).
		#  3. We remove empty lines.
		#
		printf '\n'     >> "${samplesheet}.converted"
		sed 's/\r/\n/g' "${samplesheet}.converted" > "${samplesheet}.converted.tmp"
		sed '/^\s*$/d'  "${samplesheet}.converted.tmp" > "${samplesheet}.converted.tmp2"
		rm "${samplesheet}.converted.tmp"
		mv "${samplesheet}.converted.tmp2" "${samplesheet}.converted"
		if checkSampleSheet.py --input "${samplesheet}.converted" --log "${samplesheet}.converted.log"
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "samplesheet is correct"
			check=$(cat "${samplesheet}.converted.log")
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "samplesheet is not correct"
			check=$(cat "${samplesheet}.converted.log")
		fi
		projectSamplesheet="false"
		if [[ "${check}" == *'OKAY'* ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Samplesheet is correct, continue"
			if [[ "${check}" == *'projectSamplesheet'* ]]
			then
				projectSamplesheet="true"
			fi
				
		else
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${check} for samplesheet: ${samplesheet}"
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			continue
		fi
	fi
	
	if [[ -n "${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]+isset}" ]] 
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' ""
		_pipelineFieldIndex=$((${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]} + 1))
		## In future this valueInSamplesheet will be replaced by DARWIN to the real value.
		readarray -t valueInSamplesheet < <(tail -n +2 "${samplesheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_pipelineFieldIndex}" | sort | uniq )
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "renaming ${valueInSamplesheet[0]} into ${REPLACEDPIPELINECOLUMN}"
		perl -p -e "s|${valueInSamplesheet[0]}|${REPLACEDPIPELINECOLUMN}|" "${samplesheet}" > "${samplesheet}.tmp"
		mv "${samplesheet}.tmp" "${samplesheet}"
	else
		awk -v pipeline="${REPLACEDPIPELINECOLUMN}" -v pipelineColumn="${PIPELINECOLUMN}" 'BEGIN {FS=","}{if (NR==1){print $0",pipelineColumn}{else print $0","pipeline}'
	fi
	firstStepOfPipeline="${REPLACEDPIPELINECOLUMN%%+*}"


	# Check whether the samplesheet is a project samplesheet (no NGS_Demultiplexing)
	# needs an update when we are going to use VIP into production
	if [[ ${projectSamplesheet} == "true" ]]
	then
		firstStepOfPipeline="NGS_DNA"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "the samplesheet is a project samplesheet (no NGS_Demultiplexing), samplesheet moved to ${firstStepOfPipeline}"
	fi

	samplesheetDestination="${HOSTNAME_TMP}:/groups/${GROUP}/${SCR_LFS}/Samplesheets/${firstStepOfPipeline}/"

	#
	# Move samplesheets with rsync
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pushing samplesheets using rsync to ${samplesheetDestination} ..."
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "See ${logDir}/rsync.log for details ..."
	transactionStatus='Ok'
	
	/usr/bin/rsync -vt \
		--log-file="${logDir}/rsync.log" \
		--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
		--omit-dir-times \
		--omit-link-times \
		"${samplesheet}" \
		"${samplesheetDestination}" \
	&& rm -v "${samplesheet}" >> "${JOB_CONTROLE_FILE_BASE}.started" \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to move ${samplesheet}."
		transactionStatus='Failed'
	}

	if [[ "${transactionStatus}" == 'Ok' ]]
	then
		rm -f "${samplesheet}.converted"{,.log}
		rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	
	else
		rm -f "${JOB_CONTROLE_FILE_BASE}.finished"
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
	fi

done


#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished."
trap - EXIT
exit 0