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

function copyQCRawdataToTmp() {

	local _rawdata="${1}"
	local _rawdata_job_controle_file_base="${2}"
	
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Working on ${_rawdata}"

	if [[ -e "${PRM_ROOT_DIR}/rawdata/ngs/${_rawdata}/Info/SequenceRun.csv" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sequencerun ${_rawdata} is not yet copied to tmp, start rsyncing.."
		touch "${_rawdata_job_controle_file_base}.started"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_rawdata} found on ${PRM_ROOT_DIR}, start rsyncing.."
		rsync -av --rsync-path="sudo -u ${group}-ateambot rsync" "${PRM_ROOT_DIR}/rawdata/ngs/${_rawdata}/Info/SequenceRun"* "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/trendanalysis/rawdata/${_rawdata}/" \
		|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync ${_rawdata}"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from /groups/${group}/${PRM_ROOT_DIR}/"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
		mv "${_rawdata_job_controle_file_base}."{started,failed}
		return
		}

		mv "${_rawdata_job_controle_file_base}."{started,finished}
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "For sequencerun ${_rawdata} there is no QC data, nothing to rsync.."
	fi

}

function copyQCProjectdataToTmp() {

	local _project="${1}"
	local _project_job_controle_file_base="${2}"
	
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Working on ${_project}"

	if [[ -e "${PRM_ROOT_DIR}/projects/${_project}/run01/results/multiqc_data/${_project}.run_date_info.csv" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Project ${_project} is not yet copied to tmp, start rsyncing.."
		touch "${_project_job_controle_file_base}.started"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_project} found on ${PRM_ROOT_DIR}, start rsyncing.."
		rsync -av --rsync-path="sudo -u ${group}-ateambot rsync" "${PRM_ROOT_DIR}/projects/${_project}/run01/results/multiqc_data/"* "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/trendanalysis/projects/${_project}/" \
		|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync QC data of ${_project}"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from /groups/${group}/${PRM_ROOT_DIR}/"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
		mv "${_project_job_controle_file_base}."{started,failed}
		return
		}
		rsync -av --rsync-path="sudo -u ${group}-ateambot rsync" "${PRM_ROOT_DIR}/projects/${_project}/run01/results/${_project}.csv" "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/trendanalysis/projects/${_project}/" \
		|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync samplesheet of ${_project}"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from /groups/${group}/${PRM_ROOT_DIR}/"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
		mv "${_project_job_controle_file_base}."{started,failed}
		return
		}
		mv "${_project_job_controle_file_base}."{started,finished}
	elif  [[ -e "${PRM_ROOT_DIR}/projects/${_project}/run01/results/qc/statistics/${_project}.Dragen_runinfo.csv" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Dragen project ${_project} is not yet copied to tmp, start rsyncing.."
		touch "${_project_job_controle_file_base}.started"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_project} found on ${PRM_ROOT_DIR}, start rsyncing.."
		rsync -av --rsync-path="sudo -u ${group}-ateambot rsync" "${PRM_ROOT_DIR}/projects/${_project}/run01/results/qc/statistics/"* "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/trendanalysis/dragen/${_project}/" \
		|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync dragen QC data of ${_project}"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from /groups/${group}/${PRM_ROOT_DIR}/"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
		mv "${_project_job_controle_file_base}."{started,failed}
		return
		}
		rsync -av --rsync-path="sudo -u ${group}-ateambot rsync" "${PRM_ROOT_DIR}/projects/${_project}/run01/results/${_project}.csv" "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/trendanalysis/dragen/${_project}/" \
		|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync dragen samplesheet of ${_project}"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from /groups/${group}/${PRM_ROOT_DIR}/"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
		mv "${_project_job_controle_file_base}."{started,failed}
		return
		}
		mv "${_project_job_controle_file_base}."{started,finished}

	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "For project ${_project} there is no QC data, nothing to rsync.."
	fi

}

function copyDarwinQCData() {

	local _runinfofile="${1}"
	local _tablefile="${2}"
	local _filetype="${3}"
	local _filedate="${4}"
	local _darwin_job_controle_file_base="${5}"

	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Copying ${_runinfofile} to tmp, start rsyncing.."
	touch "${_darwin_job_controle_file_base}.started"

	rsync -av --rsync-path="sudo -u ${group}-ateambot rsync" "${IMPORT_DIR}/${_filetype}"*"${_filedate}.csv" "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/trendanalysis/darwin/" \
	|| {
	log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync ${_filetype}"*"${_filedate}.csv"
	log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from ${IMPORT_DIR}/"
	log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
	mv "${_darwin_job_controle_file_base}."{started,failed}
	return
	}

	mv "${_darwin_job_controle_file_base}."{started,finished}
	mv "${IMPORT_DIR}/${_filetype}"*"${_filedate}.csv" "${IMPORT_DIR}/archive/"


}


function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (rsync) QC data from prm to tmp.
NGS project MultiQC data, sequencerun information from rawdata and everything Adlas/Darwin can produce.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g 	[group]
		Group for which to process data.
	-l 	[level]
		Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 4 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg       for the group specified with -g
		2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
		3. <source_host>.cfg for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
		4. sharedConfig.cfg  for all groups and all servers.
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
			;;
	esac
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

if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

infoServerLocation="${HOSTNAME_PRM}"
infoLocation="/groups/${group}/${PRM_LFS}/trendanalysis/"
hashedSource="$(printf '%s:%s' "${infoServerLocation}" "${infoLocation}" | md5sum | awk '{print $1}')"
lockFile="${WORKING_DIR}/trendanalysis/logs/${SCRIPT_NAME}_${hashedSource}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/trendanalysis/logs/ ..."


#
## Loops through all rawdata folders and checks if the QC data  is already copied to tmp. If not than call function copyQCRawdataToTmp
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "starting checking the prm's for raw QC data"

for prm_dir in "${ALL_PRM[@]}"
do
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "looping through ${prm_dir}"
	export PRM_ROOT_DIR="/groups/${group}/${prm_dir}/"
	readarray -t rawdataArray < <(find "${PRM_ROOT_DIR}/rawdata/ngs/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${PRM_ROOT_DIR}/rawdata/ngs/||")

	if [[ "${#rawdataArray[@]}" -eq '0' ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No rawdata found @ ${PRM_ROOT_DIR}/rawdata/ngs/."
	else
		for rawdata in "${rawdataArray[@]}"
		do
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing rawdata ${rawdata} ..."
			mkdir -p "${PRM_ROOT_DIR}/logs/${rawdata}/"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs folder: ${PRM_ROOT_DIR}/logs/${rawdata}/"
			controlFileBase="${PRM_ROOT_DIR}/logs/${rawdata}/"
			RAWDATA_JOB_CONTROLE_FILE_BASE="${controlFileBase}/rawdata.${rawdata}.${SCRIPT_NAME}"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${rawdata} ..."

			if [[ -e "${RAWDATA_JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${rawdata}."
				continue
			else
				copyQCRawdataToTmp "${rawdata}" "${RAWDATA_JOB_CONTROLE_FILE_BASE}"
			fi
		done
	fi
done


#
## Loops through all project data folders and checks if the QC data  is already copied to tmp. If not than call function copyQCProjectdataToTmp
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "starting checking the prm's for project QC data"

for prm_dir in "${ALL_PRM[@]}"
do
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "looping through ${prm_dir}"
	export PRM_ROOT_DIR="/groups/${group}/${prm_dir}/"
	readarray -t projectdata < <(find "${PRM_ROOT_DIR}/projects/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${PRM_ROOT_DIR}/projects/||")

	if [[ "${#projectdata[@]}" -eq '0' ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No projectdata found @ ${PRM_ROOT_DIR}/projects/."
	else
		for project in "${projectdata[@]}"
		do
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project} ..."
			mkdir -p "${PRM_ROOT_DIR}/logs/${project}/"
			controlFileBase="${PRM_ROOT_DIR}/logs/${project}/"
			PROJECT_JOB_CONTROLE_FILE_BASE="${controlFileBase}/project.${project}.${SCRIPT_NAME}"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project} ..."

			if [[ -e "${PROJECT_JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${project}."
				continue
			else
				copyQCProjectdataToTmp "${project}" "${PROJECT_JOB_CONTROLE_FILE_BASE}"
			fi
		done
	fi
done


#
## check if darwin left any new files for us on dat05 to copy to tmp05
#


IMPORT_DIR="/groups/${group}/${DAT_LFS}/trendanalysis/"
PRM_DARWIN_LOGS_DIR="/groups/${group}/${PRM_LFS}/logs/darwin/"

mkdir -p "${PRM_DARWIN_LOGS_DIR}"



readarray -t darwindata < <(find "${IMPORT_DIR}/" -maxdepth 1 -mindepth 1 -type f -name "*runinfo*" | sed -e "s|^${IMPORT_DIR}/||")

if [[ "${#darwindata[@]}" -eq '0' ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "no new darwin files present in ${IMPORT_DIR}"
else
	for darwinfile in "${darwindata[@]}"
	do
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Start proseccing ${darwinfile}"
		runinfoFile=$(basename "${darwinfile}" .csv)
		fileType=$(cut -d '_' -f1 <<< "${runinfoFile}")
		fileDate=$(cut -d '_' -f3 <<< "${runinfoFile}")
		tableFile="${fileType}_${fileDate}.csv"
		runinfoCSV="${runinfoFile}.csv"
		controlFileBase="${PRM_DARWIN_LOGS_DIR}"
		DARWIN_JOB_CONTROLE_FILE_BASE="${controlFileBase}/darwin.${fileType}_${fileDate}.${SCRIPT_NAME}"

		if [[ -e "${DARWIN_JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${DARWIN_JOB_CONTROLE_FILE_BASE}.finished present"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${runinfoFile} data is already processed, but there is new data on dat05, check if previous rsync went okay"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "no ${DARWIN_JOB_CONTROLE_FILE_BASE}.finished present, starting rsyncing ${tableFile} and ${runinfoCSV}"
			copyDarwinQCData "${runinfoCSV}" "${tableFile}" "${fileType}" "${fileDate}" "${DARWIN_JOB_CONTROLE_FILE_BASE}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${runinfoCSV} and ${tableFile} copied to tmp and moved to  ${IMPORT_DIR}/archive/"
		fi
	done
fi



log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished!'

trap - EXIT
exit 0

