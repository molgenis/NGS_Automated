#!/bin/bash


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
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

###################### MAIN #########################



if ls "${PRM_ROOT_DIR}/Samplesheets/"*.csv 1> /dev/null 2>&1
then
	ls "${PRM_ROOT_DIR}/Samplesheets/"*.csv > "${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_prm.txt"
fi

while read line 
do
	prmSamplesheets+=("${line}")
done<"${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_prm.txt"

echo "Logfiles will be written to ${TMP_ROOT_DIR}/logs"

for line in "${prmSamplesheets[@]}"
do

	csvFile=$(basename "${line}")
	if [[ $csvFile == *"dummy"* ]]
	then
		continue
	fi

	filePrefix="${csvFile%.*}"
	if [ ! -d "${TMP_ROOT_DIR}/logs/${filePrefix}" ]
	then
		mkdir -m 2770 "${TMP_ROOT_DIR}/logs/${filePrefix}/"
	fi

	LOGGER="${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.logger"


	## Check if samplesheet is copied
	if [[ ! -f "${TMP_ROOT_DIR}/Samplesheets/${csvFile}" || ! -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.SampleSheetCopied" ]]
        then
                rsync "${PRM_ROOT_DIR}/Samplesheets/${csvFile}" "${TMP_ROOT_DIR}/Samplesheets/"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "rsync ${PRM_ROOT_DIR}/Samplesheets/${csvFile} ${TMP_ROOT_DIR}/Samplesheets/"

                touch "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.SampleSheetCopied"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.SampleSheetCopied created"

        fi
	## Check if data is already copied to tmp

	if [ ! -d "${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}" ]
	then
		##printf "run_id,group,demultiplexing,copy_raw,projects,date\n" > ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.uploading
                ##printf "${filePrefix},${group},finished,started,," >> ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.uploading

		##CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
		##TOKEN=${CURLRESPONSE:10:32}
		##curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.uploading" -FentityName='status_overview' -Faction=update -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "starting with rsync of ${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix} to ${TMP_ROOT_DIR}/rawdata/ngs/"
		rsync -a "${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}" "${TMP_ROOT_DIR}/rawdata/ngs/"
	fi


	if [[ -d "${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}"  && ! -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.finished" ]]
	then
		##Compare how many files are on both prm and tmp
		countFilesRawDataDirTmp=$(ls "${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}"* | wc -l)
		countFilesRawDataDirPrm=$(ls "${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}"* | wc -l)

		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Counting ${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}* : ${countFilesRawDataDirPrm}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Counting ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}* : ${countFilesRawDataDirTmp}"

		if [ "${countFilesRawDataDirTmp}" -eq "${countFilesRawDataDirPrm}" ]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "tmp and prm counts are the same"
			cd "${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "navigated to ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/"
			for i in $(ls *.fq.gz.md5 )
			do
				if md5sum -c "${i}"
				then
					awk '{print $2" CHECKED, and is correct"}' $i >> "${LOGGER}"
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "md5sum is checked"
				else
					echo 'md5sum check failed' >> "${LOGGER}"
					log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "md5sum check failed for ${filePrefix}"
				fi
			done
		#	touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToDiagnosticsCluster
		#	printf "run_id,group,demultiplexing,copy_raw,projects,date\n" > ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.uploading
		#	printf "${filePrefix},${group},finished,finished,," >> ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.uploading

		#	CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
		#	TOKEN=${CURLRESPONSE:10:32}

		#	curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.uploading" -FentityName='status_overview' -Faction=update -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile

		else
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "the counts are not the same, new rsync"
			rsync -a "${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}" "${TMP_ROOT_DIR}/rawdata/ngs/" 
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "data copied to DiagnosticsCluster"
			echo 'data copied to DiagnosticsCluster' >> "${LOGGER}"
		fi

		touch "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.stagePrmDataToTmp.finished"

	fi
done

trap - EXIT
exit 0
