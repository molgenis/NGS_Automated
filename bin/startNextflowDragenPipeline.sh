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
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to stage data from prm to tmp and then start automagically the pipeline

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-r	Run number / runID (default is run01)
	-g	Group.
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg       for the group specified with -g
		2. <host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
		3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================

EOH
	trap - EXIT
	exit 0
}

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Parsing commandline arguments ..."
declare group=''
while getopts ":g:l:r:h" opt; do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		r)
			pipelineRun="${OPTARG}"
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

if [[ -z "${pipelineRun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' 'no runID is given, default is taken (run01).'
	pipelineRun="run01"
fi
#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config files ..."
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
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data trnasfers.
#
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

printf 'Started at %s.\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"

#
# Fetch (new) sample sheets from prm.
#
# ToDo: skip fetching sample sheets from prm once we have a 
#       proper prm mount on the GD clusters and the previous script
#       that created the sample sheet per project can run a GD cluster
#       instead of on a research cluster to create them directly on tmp.
#
declare -a sampleSheets
# shellcheck disable=SC2029
readarray -t sampleSheets < <(find "${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/" -mindepth 1 -maxdepth 1 -name "*.${SAMPLESHEET_EXT}" )
if [[ "${#sampleSheets[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No sample sheets found @ ${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/: There is nothing to do."
	trap - EXIT
	exit 0
else
	for sampleSheet in "${sampleSheets[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing sample sheet: ${sampleSheet} ..."
		project="$(basename "${sampleSheet}" ".${SAMPLESHEET_EXT}")"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing: ${project} ..."
		#
		# Configure logging for this project.
		#
		controlFileBase="${TMP_ROOT_DIR}/logs/${project}/${pipelineRun}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		#
		# Check if we should (re)start the pipeline.
		#
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already started ${project}/${pipelineRun}."
			continue
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${project}/${pipelineRun} ..."
		fi
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${project}/"
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		#
		# Sanity checks.
		#
		declare -a sampleSheetColumnNames=()
		declare -A sampleSheetColumnOffsets=()
		declare    sampleSheetFieldIndex
		declare    sampleSheetFieldValueCount
		IFS="${SAMPLESHEET_SEP}" read -r -a sampleSheetColumnNames <<< "$(head -1 "${sampleSheet}")"
		#
		# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
		#
		for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]} ; offset++ ))
		do
			regex='Sample Type'
			if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
			then
				columnName='sampleType'
			else
				columnName="${sampleSheetColumnNames[${offset}]}"
			fi
			sampleSheetColumnOffsets["${columnName}"]="${offset}"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${columnName} and sampleSheetColumnOffsets[${columnName}] offset ${offset}"
		done
		#
		# Get sampleType from sample sheet and check if all samples are of the same type.
		#
		sampleType='DNA' # Default.
		if [[ -n "${sampleSheetColumnOffsets['sampleType']+isset}" ]]; then
			sampleSheetFieldIndex=$((${sampleSheetColumnOffsets['sampleType']} + 1))
			sampleSheetFieldValueCount=$(tail -n +2 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleSheetFieldIndex}" | sort | uniq | wc -l)
			if [[ "${sampleSheetFieldValueCount}" -eq '1' ]]
			then
				sampleType=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleSheetFieldIndex}")
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found sampleType: ${sampleType}."
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${sampleSheet} contains multiple different sampleType values."
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping ${project} due to error in sample sheet."
				continue
			fi
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
		fi
		#
		# Get additional meta-data from samplesheet.
		# (Not required for generating and submitting job scripts; only used for track and trace.)
		#
		sampleSheetFieldIndex=$((${sampleSheetColumnOffsets['capturingKit']} + 1))
		capturingKit=$(tail -n 1 "${sampleSheet}" | awk -v sampleSheetFieldIndex="${sampleSheetFieldIndex}" 'BEGIN {FS=","}{print $sampleSheetFieldIndex}')
		
		if [[ -e "${TMP_ROOT_DIR}/logs/${project}/run01.nextflow_pipeline.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed project ${project} (${TMP_ROOT_DIR}/logs/${project}//run01.nextflow_pipeline.finished present..."
		else
			####### NEXTFLOW ######
			mkdir -p "${TMP_ROOT_DIR}/nextflow/${project}"
			#rsync -rv "${EBROOTNGS_DNA}/nextflow/"* "${TMP_ROOT_DIR}/nextflow/${project}"
		
			module load nextflow
			thisDir=$(pwd)

			cd "${TMP_ROOT_DIR}/nextflow/${project}"
			nextflow run --samplesheet "${sampleSheet}" --tmpdir "${TMP_LFS}" --group "${group}" -w "${TMP_ROOT_DIR}/nextflow/${project}" "${EBROOTNF_NGS_DNA}/main.nf"
			# || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to execute 'nextflow run' command."
			cd "${thisDir}"
		fi
		#
		# Signal success or failure for complete process.
		#
		if [[ -e "${TMP_ROOT_DIR}/logs/${project}/run01.nextflow_pipeline.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/logs/${project}/run01.nextflow_pipeline.finished present -> processing completed for ${project}/${pipelineRun} ..."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing ${project}/${pipelineRun}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/logs/${project}/run01.nextflow_pipeline.finished absent -> processing failed for ${project}/${pipelineRun}."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process ${project}/${pipelineRun}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		fi
	done
fi

printf 'Done at %s.\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
trap - EXIT
exit 0
