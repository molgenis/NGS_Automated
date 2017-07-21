#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
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
SCRIPT_NAME="$(basename ${0} .bash)"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname)"

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
    trap - EXIT
    exit 1
fi

function showHelp() {
    #
    # Display commandline help on STDOUT.
    #
    cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished analysis project from tmp to prm storage.

Usage:

    $(basename $0) OPTIONS

Options:

    -h   Show this help.
    -g   Group.
    -e   Enable email notification. (Disabled by default.)
    -n   Dry-run: Do not perform actual sync, but only list changes instead.
    -l   Log level.
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
# Source config files.
#

function generateScripts () {
	local _sampleType="${1}" ## DNA or RNA
	local _filePrefix="${2}" ## name of the run sequencingStartDate_Sequencer_run_flowcell
	local _species="${3}" ##
	local _workflowOrPanel="${4}"
	local _build="${5}"
	local _run="${6}"
	local _loadPipeline="NGS_${_sampleType}"


	if [ "${_sampleType}" == "DNA" ]
	then
		_version="${NGS_DNA_VERSION}"
		module load "${_loadPipeline}/${_version}" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to load ${_loadPipeline} module."
		_pathToPipeline="${EBROOTNGS_DNA}"
	elif [ "${_sampleType}" == "RNA" ]
	then
		_version="${NGS_RNA_VERSION}"
		module load "${_loadPipeline}/${_version}" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to load ${_loadPipeline} module."
		_pathToPipeline="${EBROOTNGS_RNA}"

	fi


	local _generateShScript="${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"generatescript is ${_generateShScript}"
        mkdir -p "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
                "created directory: ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"copying ${_pathToPipeline}/generate_template.sh to ${_generateShScript}"

        echo "copying ${_pathToPipeline}/generate_template.sh to ${_generateShScript}" >> $LOGGER
	cp "${_pathToPipeline}/generate_template.sh" "${_generateShScript}"

        perl -pi -e "s|PROJECT=projectXX|PROJECT=\"${_filePrefix}\"|" "${_generateShScript}"
        perl -pi -e "s|RUNID=runXX|RUNID=\"${_run}\"|" "${_generateShScript}"
        perl -pi -e "s|SPECIES=\"homo_sapiens\"|SPECIES=\"${_species}\"|" "${_generateShScript}"
        perl -pi -e "s|BUILD=\"b37\"|BUILD=\"${_build}\"|" "${_generateShScript}"

	if [ "${_sampleType}" == "DNA" ]
        then
		perl -pi -e "s|BATCH=\"_chr\"|BATCH=\"${_workflowOrPanel}\"|" "${_generateShScript}"
        elif [ "${_sampleType}" == "RNA" ]
	then
		perl -pi -e "s|PIPELINE=\"hisat\"|PIPELINE=\"${_workflowOrPanel}\"|" "${_generateShScript}"
        fi

        if [ -f "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.csv" ]
        then
                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.csv already existed, will now be removed and will be replaced by a fresh copy"
                echo "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.csv already existed, will now be removed and will be replaced by a fresh copy" >> $LOGGER
                rm "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.csv"
        fi

	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"copying ${TMP_ROOT_DIR}/Samplesheets/${_filePrefix}.csv to ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
        cp "${TMP_ROOT_DIR}/Samplesheets/${_filePrefix}.csv" "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"

        cd "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"navigated to $(pwd), should be the same as ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"

        log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"\nsh ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh ${_filePrefix} ${_build} ${_species} ${_workflowOrPanel} > ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.logger"
        echo "sh ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh "${_filePrefix}" ${_build} ${_species} ${_workflowOrPanel}" > "${TMP_ROOT_DIR}"/generatedscripts/"${_filePrefix}"/generate.logger
        sh "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh" "${_filePrefix}" "${_build}" "${_species}" "${_workflowOrPanel}" > "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.logger" 2>&1

        cd scripts
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"navigated to $(pwd), should be the same as ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/scripts"
        sh submit.sh
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"scripts generated, this file has been created: ${TMP_ROOT_DIR}/logs/${_filePrefix}/${_filePrefix}.scriptsGenerated"

        touch "${TMP_ROOT_DIR}/logs/${_filePrefix}/${_filePrefix}.scriptsGenerated"


}

function submitPipeline () { 

	local _project="${1}"
	local _run="${2}"

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
                        "starting to work on the submitPipeline part on project: ${_project} and run: ${_run}"


	if [ ! -d "${TMP_ROOT_DIR}/logs/${_project}" ]
	then
		mkdir "${TMP_ROOT_DIR}/logs/${_project}"
	fi

	_logger="${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.logger"
	if [[ ! -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.started"  && ! -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"working on ${_project}"

		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"navigated to: ${TMP_ROOT_DIR}/projects/${_project}/run01/jobs/"
                cd "${TMP_ROOT_DIR}/projects/${_project}/run01/jobs/"

####################################### 
### Turned the track N trace for now
##
		## creating jobs entity
                #echo -e "job\tproject_job\tproject\tstarted_date\tfinished_date\tstatus" >  "${TMP_ROOT_DIR}/logs/${_project}/jobsPerProject.tsv"
                #grep 'processJob' submit.sh | tr '"' ' ' | awk -v pro=$PROJECT '{OFS="\t"} {print $2,pro"_"$2,pro,"","",""}' >>  "${TMP_ROOT_DIR}/logs/${_project}/jobsPerProject.tsv"

                #CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
                #TOKEN=${CURLRESPONSE:10:32}
                #curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${TMP_ROOT_DIR}/logs/${_project}/jobsPerProject.tsv" -FentityName='status_jobs' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile
                #echo "curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${TMP_ROOT_DIR}/logs/${_project}/jobsPerProject.tsv" -FentityName='status_jobs' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile"
##
#######################################

		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"starting to submit jobs"
		sh submit.sh

		touch "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.started"
		echo "${_project} started" >> ${_logger}
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"${_project} started"
		printf "Pipeline: ${pipeline}\nStarttime:`date +%d/%m/%Y` `date +%H:%M`\nProject: $_project\nStarted by: ${ROLE_USER}\n \
		Host: \${HOSTNAME_SHORT}\n\nProgress can be followed via the command squeue -u $ROLE_USER on ${HOSTNAME_SHORT}.\nYou will receive an email when the pipeline is finished!\n\nCheers from the GCC :)" \
		| mail -s "NGS_DNA pipeline is started for project $_project on `date +%d/%m/%Y` `date +%H:%M`" ${EMAIL_TO}
	fi
}

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
declare email='false'
declare dryrun=''
while getopts "g:l:hen" opt; do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		e)
			email='true'
			;;
		n)
			dryrun='-n'
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
if [[ -z "${group:-}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -n "${dryrun:-}" ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Enabled dryrun option for rsync.'
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
)
for configFile in "${configFiles[@]}"; do 
	if [[ -f "${configFile}" && -r "${configFile}" ]]; then
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
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."


##
#### Copy raw data from prm to tmp
#############################################

## Here the data should be copied (what used to be CopyRawDataToCluster)




################################################
count=0 
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
                "path of Samplesheets dir: ${TMP_ROOT_DIR}/Samplesheets/*.csv"
if ls "${TMP_ROOT_DIR}/Samplesheets/"*.csv 1> /dev/null 2>&1
then
	counting=$(ls "${TMP_ROOT_DIR}/Samplesheets/"*.csv | wc -l)

	for i in $(ls "${TMP_ROOT_DIR}/Samplesheets/"*.csv) 
	do
		csvFile=$(basename "${i}")
		filePrefix="${csvFile%.*}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run: ${filePrefix}..."

		##get header to decide later which column is project
		HEADER=$(head -1 "${i}")

		##Remove header, only want to keep samples
		sed '1d' "${i}" > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp"
		IFS=','  array=(${HEADER})
		count=1

		pipeline="DNA" ##The column Sample Type is by default filled in RNA (with RNA), this column is not available in DNA
		species="homo_sapiens"
		for j in ${array[@]}
		do
			if [ "${j}" == "project" ]
			then
				awk -F"," '{print $'$count'}' "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp" > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp2"
			elif [[ "${j}" == *"Sample Type"* ]]
			then
				awk -F"," '{print $'$count'}' "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp" > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.whichPipeline"
				pipeline=$(head -1 "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.whichPipeline")

			elif [[ "${j}" == "species" ]]
			then
				awk -F"," '{print $'$count'}' "${TMP_ROOT_DIR}/tmp/NGS_Automated//${filePrefix}.tmp" > "${TMP_ROOT_DIR}/tmp/NGS_Automated//${filePrefix}.species"
				species=$(head -1 "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.species")
			elif [ "${j}" == "capturingKit" ]
			then
				awk -F"," '{print $'$count'}' "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp" > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.capturingKit"

			fi
			count=$((count + 1))
		done



		cat "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp2" | sort -V | uniq > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.projects"

		PROJECTARRAY=()
		while read line
		do
			PROJECTARRAY+="${line}"

		done<"${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.projects"
		count=1
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "The projects in this run is/are: ${PROJECTARRAY}"

		cat "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.capturingKit" | sort -V | uniq > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.capturingKits"

		panel="yes"
		while read line
		do
			if [[ "${line}" == *"Exoom"* || "${line}" == *"All_Exon"* || "${line}" == *"WGS"* || "${line}" == *"wgs"* ]] 
			then
				panel="no"
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "DNA pipeline: The batching will be per chromosome"

				break
			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "DNA pipeline: The batching will be treated as a panel (_small) "
				break
			fi
		done<"${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.capturingKits"
		LOGGER="${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.pipeline.logger"
		species="homo_sapiens"
		build="b37"
		run="run01"
		batching="_chr"


		####
		### Decide if the scripts should be created (per Samplesheet)
		##
		#
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.finished ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated"
		if [[ -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.finished" ]] && [ ! -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated" ]
		then
			for project in "${PROJECTARRAY[@]}"
			do
				projectName=${project}
			done

			if [ "${pipeline}" == "DNA" ]
			then
				if [ "${panel}" == "yes" ]
				then
					batching="_small"
				fi
				generateScripts "${pipeline}" "${filePrefix}" "${species}" "${batching}" "${build}" "${run}"
			elif [ "${pipeline}" == "RNA" ]
			then
				workflow="hisat"

				## this has to be fixed somewhere in the future, since now it will always be homo sapiens
				if [ $species != "homo_sapiens" ]
				then
					build="b38"
				fi

				if [[ "${projectName}" == *"Lexogen"* ]]
				then
					workflow="lexogen"
				fi

				generateScripts "${pipeline}" "${filePrefix}" "${specie}" "${workflow}" "${build}" "${run}"
			fi
		fi
		####
		### If generatedscripts is already done, step in this part to submit the jobs (per project)
		##
		#
		if [ -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated" ]
		then
			for project in "${PROJECTARRAY[@]}"
			do
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
				submitPipeline "${project}" "${run}"
			done
		fi
	done
else
	echo "There are no samplesheets"
fi

trap - EXIT
exit 0
