#!/bin/bash

set -e
set -u


# module load NGS_Automated/beta; pipelineTiming.sh -g umcg-atd -s gattaca02.gcc.rug.nl -r /groups/umcg-atd/scr01/ -l DEBUG

#
##		This script will run on Leucine-zipper or zinc-finger. First it will pull the project files, from projects from whom the demultiplex pipeline is finished.
###		It will check if there is a .finished file for the generateScripts, pipeline, copyProjectDataPrm, if there is, these steps are finished. 
####	If no .finished file is precent, it will check if the run0*.pipeline.started is older than 6h, 
####	*.generateScripts.started is older than 5h and the *.copyProjectDataPrm.started is older than 5(last time it was modified). 
###		If the .started is not older than 5 or 6h, no worries the pipeline is probably still running.
##		If the .started file is older than 5 or 6 hours, it wil generate a .failed file.
#

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

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
======================================================================================================================
Script to start NGS_Demultiplexing automagicly when sequencer is finished, and corresponding samplesheet is available.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g	Group.
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
	-s	Source server address from where the rawdate will be fetched
		Must be a Fully Qualified Domain Name (FQDN).
		E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl
	-r	Root dir on the server specified with -s and from where the raw data will be fetched (optional).
		By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
		<group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
		You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
		which is for example the case when fetching data from another group.

Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg	for the group specified with -g
		2. <this_host>.cfg	for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
		3. <source_host>.cfg	for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
		4. sharedConfig.cfg	for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
======================================================================================================================

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
declare sourceServerFQDN=''
declare sourceServerRootDir=''

while getopts "g:l:s:r:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			GROUP="${OPTARG}"
			;;
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
			;;
		r)
			sourceServerRootDir="${OPTARG}"
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
if [[ -z "${GROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -z "${sourceServerFQDN:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a Fully Qualified Domain Name (FQDN) for sourceServer with -s.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${GROUP}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/${sourceServer}.cfg"
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
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ ! -z "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi


#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi


checkProjectSheet=$(ssh ${ATEAMBOTUSER}@${sourceServerFQDN} "find ${SCR_ROOT_DIR}/logs/Timestamp/ -type f -name *.csv -maxdepth 1")

if [[ -z "${checkProjectSheet}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '1' "All runs are processed, no new project sheet available"
fi


logsDir="${TMP_ROOT_DIR}/logs/"
projectStartDir="${TMP_ROOT_DIR}/logs/Timestamp"

rsync -av ${sourceServerFQDN}:"${SCR_ROOT_DIR}/logs/Timestamp/*.csv" "${projectStartDir}" 

for projectSheet in $(ls "${projectStartDir}/"*".csv")
do 
	project=$(basename "${projectSheet}" .csv)

	## determine run number.
	if [ -e "${logsDir}/${project}/"*".generateScripts.finished" ]
	then
		run=$(basename "${logsDir}/${project}/"*".generateScripts.finished" .generateScripts.finished)
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using run number: ${run}"
	elif [ -e "${logsDir}/${project}/"*".generateScripts.started"  ]
	then
		run=$(basename "${logsDir}/${project}/"*".generateScripts.started" .generateScripts.started)
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using run number: ${run}"
	fi

	if [[ ! -d "${logsDir}/${project}/" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The pipeline has not started jet for project: ${project}"
		continue
	else
		touch "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
		echo -e "moment of checking run time: $(date)\nproject: ${project}\n" > "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Using project: ${project}"
	fi
	

	## step 1, checks the generatedScirps
	if [ -e "${logsDir}/${project}/${run}.generateScripts.finished" ]
	then
		echo -e "generatedScripts finished for project ${project}" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
		touch "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "generateScripts finished for project ${project}"
	else
		timeStampGeneratedScripts=$(find "${logsDir}/${project}/" -type f -mmin +240 -iname "${run}.generateScripts.started")
		if [[ -z "${timeStampGeneratedScripts}" ]]
		then
			echo -e "generateScipts has not started yet or is running" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "generateScipts has not started yet or is running for project ${project}"
			continue
		else
			echo -e "generateScripts.started file is OLDER than 4 hours.\n" \
			"time ${run}.generateScripts.started was last modified:" \
			$(stat -c %y "${TMP_ROOT_DIR}/logs/${project}/${run}.generateScripts.started") >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
	
			touch "${TMP_ROOT_DIR}/logs/${project}/${run}.generateScriptsTiming.failed"
			echo -e "Dear HPC helpdesk,\n\nPlease check if there is something wrong with the pipeline.\nThe generatedScripts step for project ${project} is not finished after 4h.\n\nKind regards\nHPC" > "${TMP_ROOT_DIR}/logs/${project}/${run}.generateScriptsTiming.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "generateScripts.started file is OLDER than 4 hours for project ${project}"
			continue
		fi
	fi

	## step 2, checks the pipeline
	if [ -e "${logsDir}/${project}/${run}.pipeline.finished" ]
	then
		echo "pipeline is finished for project ${project}" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
		touch "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "pipeline finished for project ${project}"
	else
		timeStampPipeline=$(find "${logsDir}/${project}/" -type f -mmin +600 -iname "${run}.pipeline.started")
		if [[ -z "${timeStampPipeline}" ]]
		then
			echo -e "pipeline is has not started yet or is still running" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "pipeline has not started yet or is running for project ${project}"
			continue
		else
			echo -e "pipeline.started file is OLDER than 10 hours.\n" \
			"time ${run}.pipeline.started was last modified:" \
			$(stat -c %y "${TMP_ROOT_DIR}/logs/${project}/${run}.pipeline.started") >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
			touch "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.failed"
			echo -e "Dear HPC helpdesk,\n\nPlease check if there is something wrong with the pipeline.\nThe pipeline for project ${project} is not finished after 10h.\n\nKind regards\nHPC" > "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "pipeline.started file is OLDER than 10 hours for project ${project}"
			continue
		fi
	fi 

	## step 3, check the copyProjectDataToPrm
	if [ -e "${logsDir}/${project}/${run}.copyProjectDataToPrm.finished" ]
	then
		echo -e "copyProjectDataToPrm is finished for project ${project}" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
		touch "${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrmTiming.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copyProjectDataToPrm finished for project ${project}"
	else
		timeStampCopyProjectDataToPrm=$(find "${logsDir}/${project}/" -type f -mmin +240 -iname "${run}.copyProjectDataToPrm.started")
		if [[ -z "${timeStampCopyProjectDataToPrm}" ]]
		then
			echo -e "copyProjectDataToPrm has not started jet, or is running" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copyProjectDataToPrm has not started yet or is running for project ${project}"
			continue
		else
			echo -e "copyProjectDataToPrm.started file is OLDER than 4 hours.\n" \ 
			"time ${run}.copyProjectDataToPrm.started was last modified:\n" \
			$(stat -c %y "${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrm.started") >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
			touch "${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrmTiming.failed"
			echo -e "Dear HPC helpdesk,\n\nPlease check if there is something wrong with the pipeline.\nThe copyProjectDataToPrm has started but is not finished after 6h for project ${project}.\n\nKind regards\nHPC" > "${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrmTiming.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copyProjectDataToPrm.started file OLDER than 4 hours for project ${project}"
			continue
		fi
	fi

	echo -e "The complete pipeline is finished for project ${project}" >> "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.log"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The complete pipeline is finished for project ${project}"

	ssh ${sourceServerFQDN} "mv ${SCR_ROOT_DIR}/logs/Timestamp/${project}.csv ${SCR_ROOT_DIR}/logs/Timestamp/archive/"
	mv "${projectStartDir}/${project}.csv" "${projectStartDir}/archive/"
done

trap - EXIT
exit 0
