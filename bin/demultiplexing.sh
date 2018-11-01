#!/bin/bash
set -e
set -u

if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]
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
### Functions.
##
#
if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
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

	$(basename $0) OPTIONS

Options:

	-h   Show this help.
	-g   Group.
	-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

    This script needs 3 config files, which must be located in ${CFG_DIR}:
     1. <group>.cfg	for the group specified with -g
     2. <host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
     3. sharedConfig.cfg  for all groups and all servers.
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
while getopts "g:l:h" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			GROUP="${OPTARG}"
			;;
		l)
			l4b_log_level=${OPTARG^^}
			l4b_log_level_prio=${l4b_log_levels[${l4b_log_level}]}
			;;
		\?)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Invalid option -${OPTARG}. Try $(basename $0) -h for help."
			;;
		:)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename $0) -h for help."
			;;
	esac
done

#
# Check commandline options.
#
if [[ -z "${GROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
        "${CFG_DIR}/${GROUP}.cfg"
        "${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
        "${CFG_DIR}/sharedConfig.cfg"
        "${HOME}/molgenis.cfg"
)

for configFile in "${configFiles[@]}"; do 
        if [[ -f "${configFile}" && -r "${configFile}" ]]
        then
                log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile}..."
                #
                # In some Bash versions the source command does not work properly with process substitution.
                # Therefore we source a first time with process substitution for proper error handling
                # and a second time without just to make sure we can use the content from the sourced files.
                #
                mixed_stdouterr=$(source ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot source ${configFile}."
                source ${configFile}  # May seem redundant, but is a mandatory workaround for some Bash versions.
        else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
        fi
done

#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
        log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi


### Sequencer is writing to this location: $SEQ_DIR
### Looping through to see if all files
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "ls -1 -d ${SEQ_DIR}/*/"
for i in $(ls -1 -d "${SEQ_DIR}/"*/)
do
	project=$(basename "${i}")
	pipelineLogger="${SCR_ROOT_DIR}/generatedscripts/${project}/logger.txt"

	if [ ! -d ${SCR_ROOT_DIR}/logs/${project}/ ]
	then
		mkdir ${SCR_ROOT_DIR}/logs/${project}/
	fi

	controlFileBase="${SCR_ROOT_DIR}/logs/${project}/run01.demultiplexing"
	logFile="${controlFileBase}.log"

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "working on ${project}"
	sequencer=$(echo "${project}" | awk 'BEGIN {FS="_"} {print $2}')
	miSeqCompleted="no"

        ## Check if there the run is already completed
        miSeqNameRegex='^M[0-9][0-9]*$'
        if [[ -f "${SEQ_DIR}/${project}/RTAComplete.txt" ]] && [[ "${sequencer}" =~ ${miSeqNameRegex} ]]
        then
                miSeqCompleted="yes"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Miseq run detected: miSeqCompleted=yes for ${project}."

        fi
	## Check if there the run is already completed
	if [[ -f "${SEQ_DIR}/${project}/RunCompletionStatus.xml" || "${miSeqCompleted}" == "yes" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Runstatus compleet: ${project}."
		##Check if it is a GAF or GD run
		if [ ! -f "${SCR_ROOT_DIR}/Samplesheets/${project}.csv" ]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No samplesheet for ${project}: continue."
			continue
		fi

		### SETTING PATHS
		### Check if the demultiplexing is already started
		if [ ! -f "${controlFileBase}.started" ]
		then
			checkSampleSheet.py --input "${SCR_ROOT_DIR}/Samplesheets/${project}.csv" --logfile "${logFile}"
			if [ -s "${logFile}.error" ]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${project} skipped."
				cat  "${logFile}.error" | mail -s "Samplesheet error ${project}" "${ONTVANGER}"
				rm "${logFile}.error"
				break
			else
				echo  "Samplesheet is OK" >> "${logFile}"
				#####
				## RUN PIPELINE PART ##
				#####
				echo "All checks are done. Logging from now on can be found: ${pipelineLogger}" >> "${logFile}"

				## Check if Check file (if samplesheet is already there) is existing
				if [ -f "${SCR_ROOT_DIR}/Samplesheets/${project}_Check.txt" ]
				then
					## Remove tmp Check file
                                        rm "${SCR_ROOT_DIR}/Samplesheets/${project}_Check.txt"
					echo "rm ${SCR_ROOT_DIR}/Samplesheets/${project}_Check.txt" >> "${pipelineLogger}"
				fi

					### Check if runfolder already exists
				if [ ! -d "${SCR_ROOT_DIR}/generatedscripts/${project}" ]
				then
					mkdir -p "${SCR_ROOT_DIR}/generatedscripts/${project}/"
					echo "mkdir -p ${SCR_ROOT_DIR}/generatedscripts/${project}/" >> "${pipelineLogger}"
				fi

				## Direct to generatedscripts folder
				cd "${SCR_ROOT_DIR}/generatedscripts/${project}/"

				## Copy generate script and samplesheet
				cp "${SCR_ROOT_DIR}/Samplesheets/${project}.csv" "${project}.csv"
				echo "copied ${SCR_ROOT_DIR}/Samplesheets/${project}.csv to ${project}.csv" >> "${pipelineLogger}"

				cp "${EBROOTNGS_DEMULTIPLEXING}/generate_template.sh" ./
				echo "Copied ${EBROOTNGS_DEMULTIPLEXING}/generate_template.sh to ." >> "${pipelineLogger}"
				echo "" >> "${pipelineLogger}"


				### Generating scripts
                                echo "Generated scripts" >> "${pipelineLogger}"
                                bash generate_template.sh "${project}" "${SCR_ROOT_DIR}" "${GROUP}" 2>&1 >> "${pipelineLogger}"

				check=$(tail -1 "${pipelineLogger}")
				if [[ "${check}" == *"WRONG"* ]]
				then
					echo "there is something wrong, EXIT"
					echo "###"
					echo "### Here comes the last three lines of the logger:"
					tail -3 "${pipelineLogger}"
					echo "###"
					echo "###"
					exit 1 
				fi
                                echo "cd ${SCR_ROOT_DIR}/runs/${project}/jobs" >> "${pipelineLogger}"
                                cd "${SCR_ROOT_DIR}/runs/${project}/jobs"

				bash submit.sh
                                echo "jobs submitted, pipeline is running" >> "${pipelineLogger}"

				touch "${controlFileBase}.started"
				printf "run_id,group,demultiplexing,copy_raw_prm,projects,date\n" > "${SCR_ROOT_DIR}/logs/${project}/run01.uploading.csv"
				printf "${project},${GROUP},started,,," >> "${SCR_ROOT_DIR}/logs/${project}/run01.uploading.csv"

				CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
				TOKEN=${CURLRESPONSE:10:32}

				curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${SCR_ROOT_DIR}/logs/${project}/run01.uploading.csv" -FentityTypeId='status_overview' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile

			fi
                fi
	fi
done

trap - EXIT
exit 0
