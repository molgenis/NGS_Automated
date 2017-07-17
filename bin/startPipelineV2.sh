#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
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
if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]; then
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

generateScripts () {
	_sampleType=$1 ## DNA or RNA
	_filePrefix=$2 ## name of the run sequencingStartDate_Sequencer_run_flowcell
	_specie=$3 ##
	_workflowOrPanel=$4
	_build=$5
	_run=$6
	_loadPipeline="NGS_${_sampleType}"


	if [ "${_sampleType}" == "DNA" ]
	then
		_version="${NGS_DNA_VERSION}"
		_pathToPipeline=$EBROOTNGS_DNA

	elif [ "${_sampleType}" == "RNA" ]
		_version="${NGS_RNA_VERSION}"
		_pathToPipeline=$EBROOTNGS_RNA

	fi

	module load ${_loadPipeline}/"${_version}" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to load ${_loadPipeline} module."
	_generateShScript=${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh"

        mkdir -p ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
                "created directory: ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"copying ${_pathToPipeline}/generate_template.sh to ${_generateShScript}"

        echo "copying ${_pathToPipeline}/generate_template.sh to ${_generateShScript}" >> $LOGGER
	cp ${_pathToPipeline}/generate_template.sh "${_generateShScript}"

        perl -pi -e "s|PROJECT=projectXX|PROJECT=\"\${_filePrefix}\"|" "${_generateShScript}"
        perl -pi -e "s|RUNID=runXX|RUNID=\"\${_run}\"|" "${_generateShScript}"
        perl -pi -e "s|SPECIES="homo_sapiens"|SPECIES=\"\${_specie}\"|" "${_generateShScript}"
        perl -pi -e "s|BUILD="b37"|BUILD=\"\${_build}\"|" "${_generateShScript}"

	if [ "${_sampleType}" == "DNA" ]
        then
		perl -pi -e "s|BATCH="_chr"|BATCH=\"\${workflowOrPanel}\"|" "${_generateShScript}"
        elif [ "${_sampleType}" == "RNA" ]
	then
		perl -pi -e "s|PIPELINE="hisat"|PIPELINE=\"\${workflowOrPanel}\"|" "${_generateShScript}"
        fi

        if [ -f ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/${filePrefix}.csv ]
        then
                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/${filePrefix}.csv already existed, will now be removed and will be replaced by a fresh copy"
                echo "${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/${filePrefix}.csv already existed, will now be removed and will be replaced by a fresh copy" >> $LOGGER
                rm ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/${filePrefix}.csv
        fi

	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"copying ${TMP_ROOT_DIR}/Samplesheets/${csvFile} to ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/${filePrefix}.csv"
        cp ${TMP_ROOT_DIR}/Samplesheets/${csvFile} ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/${filePrefix}.csv

        cd ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"navigated to $pwd, should be the same as ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/"

        log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"sh ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/generate.sh ${filePrefix} ${build} ${specie} ${workflowOrPanel}"
        echo "sh ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/generate.sh "${filePrefix}" ${build} ${specie} ${workflowOrPanel}" > ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/generate.logger
        sh ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/generate.sh "${filePrefix}" ${build} ${specie} ${workflowOrPanel} > ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/generate.logger 2>&1

        cd scripts
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"navigated to $pwd, should be the same as ${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/scripts"
        touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.pipeline.locked
        sh submit.sh
        rm ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.pipeline.locked
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"scripts generated, this file has been created: ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated"

        touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated


}

submitPipeline () { 

	_project=$1
	_run=$2
	if [ ! -d ${LOGDIR}/${_project} ]
	then
		mkdir ${LOGDIR}/${_project}
	fi

	_logger=${LOGDIR}/${_project}/${_project}.pipeline.logger
	if [[ ! -f ${LOGDIR}/${_project}/${_run}.pipeline.started  && ! -f ${LOGDIR}/${_project}/${_run}.pipeline.locked && ! -f ${LOGDIR}/${_project}/${_run}.pipeline.finished ]]
	then
		"working on ${_project}"

                touch ${LOGDIR}/${_project}/${_run}.pipeline.locked
                cd ${PROJECTSDIR}/${_project}/run01/jobs/
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"navigated to: ${PROJECTSDIR}/${_project}/run01/jobs/"
####################################### 
### Turned the track N trace for now
##
		## creating jobs entity
                #echo -e "job\tproject_job\tproject\tstarted_date\tfinished_date\tstatus" >  ${LOGDIR}/${_project}/jobsPerProject.tsv
                #grep 'processJob' submit.sh | tr '"' ' ' | awk -v pro=$PROJECT '{OFS="\t"} {print $2,pro"_"$2,pro,"","",""}' >>  ${LOGDIR}/${_project}/jobsPerProject.tsv

                #CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
                #TOKEN=${CURLRESPONSE:10:32}
                #curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${LOGDIR}/${_project}/jobsPerProject.tsv" -FentityName='status_jobs' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile
                #echo "curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${LOGDIR}/${_project}/jobsPerProject.tsv" -FentityName='status_jobs' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile"
##
#######################################

                sleep 10

		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"starting to submit jobs"
		sh submit.sh

		touch "${LOGDIR}"/"${_project}"/"${_project}".pipeline.started
		echo "${_project} started" >> ${_logger}
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"${_project} started"
		printf "Pipeline: ${pipeline}\nStarttime:`date +%d/%m/%Y` `date +%H:%M`\nProject: $PROJECT\nStarted by: $WHOAMI\n \
		Host: \${HOSTN}\n\nProgress can be followed via the command squeue -u $WHOAMI on $HOSTN.\nYou will receive an email when the pipeline is finished!\n\nCheers from the GCC :)" \
		| mail -s "NGS_DNA pipeline is started for project $PROJECT on `date +%d/%m/%Y` `date +%H:%M`" ${ONTVANGER}

		sleep 40
		rm -f "${LOGDIR}"/"${_project}"/"${_run}".pipeline.locked
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


##
#### Copy raw data from prm to tmp
#############################################

## Here the data should be copied (what used to be CopyRawDataToCluster)




################################################
count=0 

if ls ${TMP_ROOT_DIR}/Samplesheets/*.csv 1> /dev/null 2>&1
then
	counting=$(ls ${TMP_ROOT_DIR}/Samplesheets/*.csv | wc -l)

	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking $counting files "

	for i in $(ls ${TMP_ROOT_DIR}/Samplesheets/*.csv) 
	do

		csvFile=$(basename $i)
		filePrefix="${csvFile%.*}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run: ${filePrefix}..."

		##get header to decide later which column is project
		HEADER=$(head -1 ${i})

		##Remove header, only want to keep samples
		sed '1d' $i > ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp
		OLDIFS=$IFS
		IFS=','
		array=($HEADER)
		IFS=$OLDIFS
		count=1

		pipeline="DNA" ##The column Sample Type is by default filled in RNA (with RNA), this column is not available in DNA
		specie="homo_sapiens"
		for j in "${array[@]}"
		do
			if [ "${j}" == "project" ]
			then
				awk -F"," '{print $'$count'}' ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp > ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp2
			elif [[ "${j}" == *"Sample Type"* ]]
			then
				awk -F"," '{print $'$count'}' ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp > ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.whichPipeline
				pipeline=$(head -1 ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.whichPipeline)

			elif [[ "${j}" == "specie" ]]
			then
				awk -F"," '{print $'$count'}' ${TMP_ROOT_DIR}/tmp/NGS_Automated//${filePrefix}.tmp > ${TMP_ROOT_DIR}/tmp/NGS_Automated//${filePrefix}.specie
				specie=$(head -1 ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.specie)
			elif [ "${j}" == "capturingKit" ]
			then
				awk -F"," '{print $'$count'}' ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp > ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.capturingKit

			fi
			count=$((count + 1))
		done



		cat ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp2 | sort -V | uniq > ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.projects

		PROJECTARRAY=()
		while read line
		do
			PROJECTARRAY+="${line} "

		done<${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.projects
		count=1
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "The projects in this run is/are: ${PROJECTARRAY}"

		cat ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.capturingKit | sort -V | uniq > ${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.capturingKits	

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
		done<${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.uniq.capturingKits
		LOGGER=${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.pipeline.logger

		####
		### Decide if the scripts should be created (per Samplesheet)
		##
		#
		if [[ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyRawDataToDiagnosticsCluster.finished || -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyRawDataToCluster.finished ]] && [ ! -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated ]
		then

		for PROJECT in ${PROJECTARRAY[@]}
		do
			projectName=${_project}
		done
		specie="homo_sapiens"
		build="b37"
		run="run01"

		if [ "${pipeline}" == "DNA" ]
		then
			if [ "${panel}" == "yes" ]
			then
				_batching="_small"
                        fi

			generateScripts "${pipeline}" "${filePrefix}" "${specie}" "${_batching}" "${build}" "${run}"

		elif [ "${pipeline}" == "RNA" ]
		then
			## this has to be fixed somewhere in the future, since now it will always be homo sapiens
			if [ $specie != "homo_sapiens" ]
                        then
				build="b38"
			fi

			if [[ "${projectName}" == *"Lexogen"* ]]
                        then
				workflow="lexogen"
                        fi

                        workflow="hisat"
                        generateScripts "${pipeline}" "${filePrefix}" "${specie}" "${workflow}" "${build}" "${run}"
		fi

		####
		### If generatedscripts is already done, step in this part to submit the jobs (per project)
		##
		#
		if [ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated ] 
		then
			for project in ${PROJECTARRAY[@]}
			do
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
				submitPipeline "$project"
			done
		fi
	done
	else
	echo "There are no samplesheets"
fi

trap - EXIT
exit 0
