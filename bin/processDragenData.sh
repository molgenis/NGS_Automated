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

function sanityChecking(){
	local _sampleProcessStepID="${1}"
	local _gsBatch="${2}"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_rawDataItem} ..."
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already transferred ${_rawDataItem}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	
	## check if all files are there 
	## per sample check: 
	##	- 1 bam file + index + md5
	## 	- 1 vcf file + index + md5
	## 	- 1 gvcf file + index + md5
	
	"${TMP_ROOT_DIR}/${_gsBatch}"

}

function renameDragenData(){
	local _sampleProcessStepID="${1}"
	local _externalSampleID="${2}"	


}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to process GenomeScan data:
	1. Convert FastQ files to format required by NGS_DNA / NGS_RNA piplines.
	2. Supplement samplesheets with meta-data from the sequencing experiment.
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Parsing commandline arguments..."
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
			;;
	esac
done

#
# Check commandline options.
#
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config files..."
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
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile}..."
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
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."



#
# Get a list of all GenomeScan batch directories.
#
readarray -t gsBatchDirs < <(find "${TMP_ROOT_DIR}/" -maxdepth 1 -mindepth 1 -type d -name "[0-9]*-[0-9]*")
log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found gsBatchDirs: ${gsBatchDirs[*]:-}"

if [[ "${#gsBatchDirs[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No batch directories found in ${TMP_ROOT_DIR}/"
else
	for gsBatchDir in "${gsBatchDirs[@]}"
	do
		#
		# Process this batch.
		#
		gsBatch="$(basename "${gsBatchDir}")"
		controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		#
		# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed batch ${gsBatch}."
			continue
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing batch ${gsBatch}..."
		fi
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	
		if [[ -e "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished present -> Data transfer completed; let's process batch ${gsBatch}..."
			_sampleSheet="GS_DRAGEN_1.csv"
			#
			# Get fields (columns) from samplesheet.
			#
			declare -a sampleSheetColumnNames=()
			declare -A sampleSheetColumnOffsets=()
			IFS="," read -r -a sampleSheetColumnNames <<< "$(head -1 "${sampleSheet}")"
			for (( _offset = 0 ; _offset < ${#sampleSheetColumnNames[@]:-0} ; _offset++ ))
			do
			  	sampleSheetColumnOffsets["${sampleSheetColumnNames[${_offset}]}"]="${_offset}"
			done
			#### CHANGE externalSampleId check TO sampleProcessStepID!!!
			if [[ -n "${_sampleSheetColumnOffsets["externalSampleID"]+isset}" ]]
			then
				#_sampleProcessStepIDFieldIndex=$((${_sampleSheetColumnOffsets["sampleProcessStepID"]} + 1))
				#### CHANGE barcode check TO sampleProcessStepID!!!
				sampleProcessStepIDFieldIndex=$((${sampleSheetColumnOffsets["barcode"]} + 1))
				externalSampleIDFieldIndex=$((${sampleSheetColumnOffsets["externalSampleID"]} + 1))
			else
				echo "does not exist in the header"
				continue
			fi

			count='0'
			while read line
			do
				if [[ "${count}" == '0' ]]
				then
					count='1'
				else
					externalSampleID=$(echo ${line} | cut -d "," -f "${externalSampleIDFieldIndex}")
					sampleProcessStepID=$(echo ${line} | cut -d "," -f "${sampleProcessStepIDFieldIndex}")
					sanityChecking "${sampleProcessStepID}" "${gsBatch}" "${controlFileBase}"


					renameDragenData ${sampleProcessStepID} ${externalSampleID}
					echo "${sampleProcessStepID}-${externalSampleID}"
				fi
			done<"${_sampleSheet}"
					
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished absent -> Data transfer not yet completed; skipping batch ${gsBatch}."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Data transfer not yet completed; skipping batch ${gsBatch}."
			continue
		fi
		#
		# Step 2: Rename FastQs if Sanity check has finished.
		#
		if [[ -e "${controlFileBase}.sanityChecking.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.sanityChecking.finished present -> sanityChecking completed; let's renameFastQs for batch ${gsBatch}..."
			renameDragenData "${gsBatch}" "${controlFileBase}"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.sanityChecking.finished absent -> sanityChecking failed."
		fi
		#
		# Step 3: Process samplesheets and move converted data if renaming of FastQs has finished.
		#
		if [[ -e "${controlFileBase}.renameFastQs.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.renameFastQs.finished present -> renameFastQs completed; let's mergeSamplesheetPerProject for batch ${gsBatch}..."
			processSamplesheetsAndMoveConvertedData "${gsBatch}" "${controlFileBase}"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.renameFastQs.finished absent -> renameFastQs failed."
		fi
		#
		# Signal success or failure for complete process.
		#
		if [[ -e "${controlFileBase}.processSamplesheetsAndMoveConvertedData.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.processSamplesheetsAndMoveConvertedData.finished present -> processing completed for batch ${gsBatch}..."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing batch ${gsBatch}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.processSamplesheetsAndMoveConvertedData.finished absent -> processing failed for batch ${gsBatch}."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process batch ${gsBatch}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		fi
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' 'Finished processing all batches.'

trap - EXIT
exit 0
