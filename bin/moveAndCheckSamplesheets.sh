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
	Script to check samplesheets and move them to another location, potentially on another server.

Usage:
	$(basename "${0}") OPTIONS
Options:
	-h	Show this help.
	-d	DAT_DIR
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
while getopts ":g:l:d:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		d)
			dat_dir="${OPTARG}"
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

if [[ -z "${dat_dir:-}" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "default (${DAT_ROOT_DIR})"
else
	# shellcheck disable=SC2153
	DAT_ROOT_DIR="/groups/${GROUP}/${dat_dir}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "DAT_ROOT_DIR is set to ${DAT_ROOT_DIR}"
	if test -e "/groups/${GROUP}/${dat_dir}/"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DAT_ROOT_DIR} is available"
		
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "${DAT_ROOT_DIR} does not exist, exit!"
	fi
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
#


samplesheetsSource="${DAT_ROOT_DIR}/samplesheets/new/"
samplesheetsSourceFolderChecked="${DAT_ROOT_DIR}/samplesheets/"
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

else
	for samplesheet in "${samplesheets[@]}"
	do
		sampleSheetName=$(basename "${samplesheet%.*}")
		logDir="${DAT_ROOT_DIR}/logs/${sampleSheetName}/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${logDir}"
		touch "${logDir}"
		export JOB_CONTROLE_FILE_BASE="${logDir}/${sampleSheetName}.${SCRIPT_NAME}"
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"

		#
		# Make sure
		#  1. The last line ends with a line end character.
		#  2. We have the right line end character: convert any carriage return (\r) to newline (\n).
		#  3. We remove empty lines.
		#
		cp "${samplesheet}"{,.converted}
		printf '\n'     >> "${samplesheet}.converted"
		sed -i 's/\r/\n/g' "${samplesheet}.converted"
		sed -i "/^[\s${SAMPLESHEET_SEP}]*$/d" "${samplesheet}.converted"
		mv "${samplesheet}.converted" "${samplesheet}"

		declare -a _sampleSheetColumnNames=()
		declare -A _sampleSheetColumnOffsets=()

		IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${samplesheet}")"
	
		for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
		do
			_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
		done

		projectSamplesheet="false"
		if [[ -n "${_sampleSheetColumnOffsets["SentrixBarcode_A"]+isset}" ]] 
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a GAP samplesheet. There is no samplesheetCheck at this moment."
		elif [[ "${samplesheet}" == *"GS_"* ]] 
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a GS samplesheet. No samplesheetCheck (yet).. A lot of required columns for in house are not required for GS"	
			projectSamplesheet="true"
		elif [[ "${group}" == "patho" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a Patho samplesheet. There is no need for samplesheetCheck."
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a NGS samplesheet. Lets check if the samplesheet is correct."
			#
			# We want to check whether the samplesheet is a project samplesheet or a rawdata samplesheet
			if checkSampleSheet.py --input "${samplesheet}" --log "${samplesheet}.log"
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Samplesheet ${samplesheet} is correct."
				check=$(cat "${samplesheet}.log")
				if [[ "${check}" == *'projectSamplesheet'* ]]
				then
					projectSamplesheet="true"
				fi
			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Samplesheet ${samplesheet} contains errors."
				check=$(cat "${samplesheet}.log")
			
				log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${check} for samplesheet: ${samplesheet}"
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				continue
			fi
		fi
	
		if [[ -n "${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]+isset}" ]] 
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "column [${PIPELINECOLUMN}] is found in the samplesheet"
			_pipelineFieldIndex=$((${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]} + 1))
			## In future this valueInSamplesheet will be replaced by DARWIN to the real value.
			readarray -t valueInSamplesheet < <(tail -n +2 "${samplesheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_pipelineFieldIndex}" | sort | uniq )
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "renaming ${valueInSamplesheet[0]} into ${REPLACEDPIPELINECOLUMN}"
			perl -p -e "s|${valueInSamplesheet[0]}|${REPLACEDPIPELINECOLUMN}|" "${samplesheet}" > "${samplesheet}.tmp"
			mv "${samplesheet}.tmp" "${samplesheet}"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "There is no column [${PIPELINECOLUMN}] in the samplesheet, creating dummy entry:"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "header: ${PIPELINECOLUMN} and value: ${REPLACEDPIPELINECOLUMN}"
			awk -v pipeline="${REPLACEDPIPELINECOLUMN}" -v pipelineColumn="${PIPELINECOLUMN}" 'BEGIN {FS=","}{if (NR==1){print $0","pipelineColumn}else{ print $0","pipeline}}' "${samplesheet}" > "${samplesheet}.tmp"
			mv "${samplesheet}.tmp" "${samplesheet}"
		fi
		firstStepOfPipeline="${REPLACEDPIPELINECOLUMN%%+*}"
		#
		# Distribute samplesheet to other dat folders
		#
		# shellcheck disable=SC2068
		for datDir in ${ARRAY_OTHER_DAT_LFS_ISILON[@]}
		do
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "copying ${samplesheet} /groups/${GROUP}/${datDir}/Samplesheets/"
			rsync -v "${samplesheet}" "/groups/${GROUP}/${datDir}/Samplesheets/"
		done
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Moving samplesheet one folder upstream: ${samplesheetsSourceFolderChecked}"
		
		mv -v "${samplesheet}" "${samplesheetsSourceFolderChecked}"
		
		rm -f "${samplesheet}.converted"{,.log}

	done
fi

readarray -t samplesheetsChecked < <(find "${samplesheetsSourceFolderChecked}" -maxdepth 1 -mindepth 1 -type f -name "*.${SAMPLESHEET_EXT}")
if [[ "${#samplesheetsChecked[@]}" -eq '0' ]]
then
#	logTimeStamp="$(date "+%Y-%m-%d")"
#	logDir="${DAT_ROOT_DIR}/logs/${logTimeStamp}/"
	# shellcheck disable=SC2174
#	mkdir -m 2770 -p "${logDir}"
#	touch "${logDir}"
#	export JOB_CONTROLE_FILE_BASE="${logDir}/${logTimeStamp}.${SCRIPT_NAME}"
#	printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No samplesheets found in ${samplesheetsSourceFolderChecked}."
	trap - EXIT
	exit 0
fi

for samplesheetChecked in "${samplesheetsChecked[@]}"
do
	# if samplesheets[@] is empty this means that the samplesheet is coming from a different machine, so we need logDir and a ${JOB_CONTROLE_FILE_BASE}.started file
	if [[ "${#samplesheets[@]}" -eq '0' ]]
	then
		sampleSheetName=$(basename "${samplesheetChecked%.*}")
		logDir="${DAT_ROOT_DIR}/logs/${sampleSheetName}/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${logDir}"
		touch "${logDir}"
		export JOB_CONTROLE_FILE_BASE="${logDir}/${sampleSheetName}.${SCRIPT_NAME}"
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	fi
	
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()

	IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${samplesheetChecked}")"
	
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done

	firstStepOfPipeline="${REPLACEDPIPELINECOLUMN%%+*}"
	projectSamplesheet='false'
	if [[ -n "${_sampleSheetColumnOffsets["SentrixBarcode_A"]+isset}" ]] 
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a GAP samplesheet. There is no samplesheetCheck at this moment."
		projectSamplesheet="false"
	elif [[ "${samplesheetChecked}" == *"GS_"* ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a GS samplesheet. No samplesheetCheck (yet).. A lot of required columns for in house are not required for GS"
		projectSamplesheet="true"
	elif [[ "${group}" == "patho" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "This is a Patho samplesheet. There is no need for samplesheetCheck."
		projectSamplesheet="false"
	else
	# We want to check whether the samplesheet is a project samplesheet or a rawdata samplesheet
		if checkSampleSheet.py --input "${samplesheetChecked}" --log "${samplesheetChecked}.log"
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if samplesheet is project samplesheet"
			check=$(cat "${samplesheetChecked}.log")
			if [[ "${check}" == *'projectSamplesheet'* ]]
			then
				projectSamplesheet="true"
			fi
		fi
	fi
	#
	# When samplesheet is GENOMESCAN the samplesheet has to go to the Samplesheets root folder (no bucket)
	#
	if [[ "${projectSamplesheet}" == "true" ]]
	then
		if [[ "${REPLACEDPIPELINECOLUMN}" == *"DRAGEN"* ]]
		then
			firstStepOfPipeline=''
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The samplesheet is a GENOMESCAN project samplesheet, the first step of the pipeline will be set to an empty string (samplesheet will be put in correct bucket in a later stage of the pipeline)."
		else
			firstStepOfPipeline="NGS_DNA"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The samplesheet is a project samplesheet (no NGS_Demultiplexing); firstStepOfPipeline was set to ${firstStepOfPipeline}."
		fi
	fi
	# shellcheck disable=SC2153
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
		--omit-link-times \
		"${samplesheetChecked}" \
		"${samplesheetDestination}" \
	&& rm -v "${samplesheetChecked}" >> "${JOB_CONTROLE_FILE_BASE}.started" \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to move ${samplesheetChecked}."
		transactionStatus='Failed'
	}

	if [[ "${transactionStatus}" == 'Ok' ]]
	then
		rm -f "${samplesheetChecked}"{,.log}
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
