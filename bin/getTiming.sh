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
===============================================================================================================
Script to get the running times of the complete pipeline

Usage:
	$(basename "${0}") OPTIONS

Options:
	-h	Show this help.
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
##
### Main.
##
#


#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
declare group=''
declare email='false'
while getopts "g:l:h" opt
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
if [[ -z "${group:-}" ]]; then
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
# Execution of this script requires ateambot account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi


workDir="${PRM_ROOT_DIR}"
projectsDir="${workDir}/projects/"
logsDir="${workDir}/logs/"
logsDirSourceServer="/groups/${GROUP}/${SCR_LFS}/logs/"

cd "${projectsDir}"
find * -nowarn -mtime -40 -type d -maxdepth 0 -exec ls -d {} \; > "${logsDir}/AllProjects40days.txt"
SAMPLESHEET_SEP=","
echo -e "unique_id,rawdataname,project,total_min,total_hours,machine,numberofSamples,startTime,finishedTime,copyRawDataToPrmDuration,pipelineDuration,copyProjectDataToPrmTiming,demultiplexingDuration" > ${logsDir}/status_timing.csv
while read project
do
	echo "start"
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	numberOfSamples=$(ls ${projectsDir}/${project}/run01/results/variants/*.final.vcf.gz | wc -l)
	sampleSheet="${projectsDir}/${project}/run01/results/${project}.csv"
	IFS="," sampleSheetColumnNames=($(head -1 "${sampleSheet}"))
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]:-0} ; offset++ ))
	do
		columnName="${sampleSheetColumnNames[${offset}]}"
		sampleSheetColumnOffsets["${columnName}"]="${offset}"
	done
	sequencingStartDateIndex=$((${sampleSheetColumnOffsets['sequencingStartDate']} + 1))
	sequencerIndex=$((${sampleSheetColumnOffsets['sequencer']} + 1))
	runIDIndex=$((${sampleSheetColumnOffsets['run']} + 1))
	flowcellIndex=$((${sampleSheetColumnOffsets['flowcell']} + 1))
	sequencingStartDate=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${sequencingStartDateIndex})
	sequencer=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${sequencerIndex})
	runID=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${runIDIndex})
	flowcell=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${flowcellIndex})
	echo "${sequencingStartDate}_${sequencer}_${runID}_${flowcell}"
	filePrefix="${sequencingStartDate}_${sequencer}_${runID}_${flowcell}"
	if [[ ${sequencer} == N* || ${sequencer} == M* ]]
	then
		if ssh ${sourceServerFQDNprimary} -n test -e "${logsDirSourceServer}/${filePrefix}/run01.demultiplexing.finished"
		then
			start=$(ssh -n ${sourceServerFQDNprimary} stat -c '%Y' "${logsDirSourceServer}/${filePrefix}/run01.demultiplexing.finished" )
			machine="${HOSTNAME_TMP}"
		else
			if ssh ${sourceServerFQDNsecondary} -n test -e "${logsDirSourceServer}/${filePrefix}/run01.demultiplexing.finished"
			then
				start=$(ssh -n ${sourceServerFQDNsecondary} stat -c '%Y'  "${logsDirSourceServer}/${filePrefix}/run01.demultiplexing.finished")
				machine="${sourceServerFQDNsecondary}"
			else
				echo "no StartTime found for ${filePrefix}"
				start="2000-00-00 00:00:00"
			fi
		fi
	else
		if ssh ${genomeScanCluster} -n test -e "/groups/umcg-genomescan/${genomeScanClusterTmp}/runs/${filePrefix}/results/${filePrefix}.csv"
		then
			machine="${HOSTNAME_TMP}"
			start=$(ssh -n ${genomeScanCluster} stat -c '%Y' "/groups/umcg-genomescan/${genomeScanClusterTmp}/runs/${filePrefix}/results/${filePrefix}.csv")
		fi
	fi
	startDateEpoch=$(echo "${start}")
	startCopyingEpoch=$(stat -c '%Y' ${logsDir}/${filePrefix}/run01.copyRawDataToPrm.started)
	finishedCopyingEpoch=$(stat -c '%Y' ${logsDir}/${filePrefix}/run01.copyRawDataToPrm.finished)
	startPipelineEpoch=$(stat -c '%Y' "${projectsDir}/${project}/run01/jobs/submit.sh")
	finishedPipelineEpoch=$(stat -c '%Y' "${projectsDir}/${project}/run01/jobs/pipeline.finished")
	finishedProjectDataToPrmEpoch=$(ssh -n ${HOSTNAME_TMP} stat -c '%Y' "/groups/${group}/${DIAGNOSTICS_TMP_LFS}/logs/${project}/run01.copyProjectDataToPrm.finished")
	totalDurationInMin=$(((finishedProjectDataToPrmEpoch-startDateEpoch)/ 60))
	totalDurationInHr=$(((finishedProjectDataToPrmEpoch-startDateEpoch)/ 3600))
	copyRawDataToPrmDuration=$(((finishedCopyingEpoch-startCopyingEpoch)/ 60))
	pipelineDuration=$(((finishedPipelineEpoch-startPipelineEpoch)/ 60))
	copyProjectDataToPrmDuration=$(((finishedProjectDataToPrmEpoch-finishedPipelineEpoch)/ 60))
	startDate=$(date -d "@${start}" +'%FT%T%z')
	finishedDate=$(date -d "@${finishedProjectDataToPrmEpoch}" +'%FT%T%z')
	echo -e "${filePrefix}-${project},${filePrefix},${project},${totalDurationInMin},${totalDurationInHr},${machine},${numberOfSamples},${startDate},${finishedDate},${copyRawDataToPrmDuration},${pipelineDuration},${copyProjectDataToPrmDuration}," >> ${logsDir}/status_timing.csv
	trackAndTracePostFromFile 'status_timing' 'add_update_existing' "${logsDir}/status_timing.csv"
	echo "Sequencing run id ${filePrefix} started on ${startDate} on ${machine}. It contains project: ${project} and it has ${numberOfSamples} samples."
	echo "The copying of the project data to prm finished at ${finishedDate}, in total this was ${totalDurationInMin} minutes (approx. ${totalDurationInHr} hours)"
done < "${logsDir}/AllProjects40days.txt"

trap - EXIT
exit 0
