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

function contains() {
	local n=$#
	local value=${!n}
	for ((i=1;i < $#;i++)) {
		if [[ "${!i}" == "${value}" ]]
		then
			echo "y"
			return 0
		fi
	}
	echo "n"
	return 1
}

function rsyncRuns() {
	local _rawDataItem="${1}"
	local _controlFileBase="${2}"
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
	#
	# Track and Trace: log that we will start rsyncing to prm.
	#
	#trackAndTracePut 'status_overview' "${_rawDataItem}" 'copy_raw_prm' 'started'
	#
	# Perform rsync.
	#  1. For ${_rawDataItem} dir: recursively with "default" archive (-a),
	#     which checks for differences based on file size and modification times.
	#     No need to use checksums here as we will verify checksums later anyway.
	#  2. For *.md5 list of checksums with archive (-a) and -c to determine
	#     differences based on checksum instead of file size and modification time.
	#     It is vitally important (and computationally cheap) to make sure
	#     the list of checksums is complete and up-to-date!
	#
	# ToDo: Do we need to add --delete to get rid of files that should no longer be there
	#       if an analysis run got updated?
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_rawDataItem} dir ..."
	# shellcheck disable=SC2174
	mkdir -m 2750 -p "${PRM_ROOT_DIR}/rawdata/"
	local _rawDataType
	for _rawDataType in "${RAWDATATYPES[@]}"
	do
		#
		# Create/check dirs.
		#
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating: ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem} ..."
		# shellcheck disable=SC2174
		mkdir -m 2750 -p "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/"
		# shellcheck disable=SC2174
		mkdir -m 2750 -p "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}"
		#
		# Transfer data.
		#
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Rsyncing ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem} to ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/ ..."
		rsync -vrltDL "${dryrun:---progress}" \
			--log-file="${_controlFileBaseForFunction}.started" \
			--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
			"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}" \
			"${PRM_ROOT_DIR}/rawdata/${_rawDataType}/" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync ${_rawDataItem}"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from ${sourceServerFQDN}:${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}/"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/"
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Sanity check.
		#
		#  1. Firstly do a quick count of the amount of files to make sure we are complete.
		#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
		#  2. Secondly verify checksums on the destination.
		#
		local _countFilesRunDirScr
		local _countFilesRunDirPrm
		# shellcheck disable=SC2029
		_countFilesRunDirScr="$(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "find \"${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}/\"* -type f | wc -l")"
		_countFilesRunDirPrm="$(find "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}/"* -type f | wc -l)"
		local _checksumVerification='unknown'
		if [[ "${_countFilesRunDirScr}" -ne "${_countFilesRunDirPrm}" ]]; then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files for ${_rawDataItem} on tmp (${_countFilesRunDirScr}) and prm (${_countFilesRunDirPrm}) is NOT the same!"
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Amount of files on tmp and prm is the same for ${_rawDataItem}: ${_countFilesRunDirPrm}."
		fi
		#
		# Verify checksums on prm storage.
		#
		if [[ "${_rawDataType}" == 'array/IDAT' ]]
		then
			#
			# ToDo: WTF, why don't we perform checksum validation here?
			#
			_checksumVerification='PASS'
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Starting verification of checksums by ${DATA_MANAGER}@${sourceServerFQDN} using checksums from ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}/*.md5 ..." \
			_checksumVerification="$(cd "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}"
				if md5sum -c -- *.md5 >> "${_controlFileBaseForFunction}.started" 2>&1
				then
					echo 'PASS'
				else
					echo 'FAILED'
				fi
			)"
		fi
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
		if [[ "${_checksumVerification}" == 'FAILED' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed for ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_rawDataItem}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		elif [[ "${_checksumVerification}" == 'PASS' ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
		fi
	done
	#
	# All is well; add new status info to *.started file and
	# delete any previously created *.failed file if present,
	# then move the *.started file to *.finished.
	# (Note: the content of *.finished will get inserted in the body of email notification messages,
	# when enabled in <group>.cfg for use by notifications.sh)
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully transferred ${_rawDataItem} to prm."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Setting track & trace state to finished :)."
	#trackAndTracePut 'status_overview' "${_rawDataItem}" 'copy_raw_prm' 'finished'
}

function splitSamplesheetPerProject() {
	local _sampleSheet="${1}"
	local _run="${2}"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction
	_controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${_run} ..."
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed ${_run}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue ..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	#
	# Rsync samplesheet to prm samplesheets folder.
	#
	rsync -vrltD "${dryrun:---progress}" \
		--log-file="${_controlFileBaseForFunction}.started" \
		--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
		"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/${pipeline}/${_run}.${SAMPLESHEET_EXT}" \
		"${PRM_ROOT_DIR}/Samplesheets/archive/" \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Failed to rsync ${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	#
	# Parse samplesheet to get a list of:
	#  * project values
	#  * analysis values (which analysis to perform for the samples of a project)
	#    When DEMULTIPLEXING ONLY is specified, the project based samplesheets are not copied to the location
	#    where they will trigger the next step of NGS_Automated.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	local      _project
	declare -a _pipelines=()
	local      _pipeline
	declare -a _demultiplexOnly=("n")
	IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${_sampleSheet}")"
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	
	#
	# Get project values from samplesheet.
	#
	if [[ -n "${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]+isset}" ]]; then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]} + 1))
		readarray -t _projects< <(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq )
		if [[ "${#_projects[@]}" -lt '1' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one value in the ${PROJECTCOLUMN} column."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in samplesheet."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run} contains the projects: ${_projects[*]}."
			printf '%s\n' "project,run_id,pipeline,url,capturingKit,message,copy_results_prm,finishedDate" \
				> "${JOB_CONTROLE_FILE_BASE}.trace_post_projects.csv"
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}, because ${PROJECTCOLUMN} column is missing in samplesheet."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Process projects from samplesheet.
	#
	for _project in "${_projects[@]}"
	do
		#
		# Track and Trace for project.
		#
		printf '%s\n' "${_project},${_run},,,,,," >> "${JOB_CONTROLE_FILE_BASE}.trace_post_projects.csv"
		#
		# Create samplesheet per project unless
		#  * either only demultiplexing was requested via the samplesheet
		#  * or when disabled on the commandline by enabling "archiveMode".
		#
		if [[ "${mergedSamplesheet}" == 'true' ]]
		then
			_project=$(echo "${_project}" | grep -Eo 'GS_[0-9]+')
		fi
		
		if [[ "${archiveMode}" == 'false' ]]; then
			#
			# Skip project if demultiplexing only.
			#
			local _projectSampleSheet
			_projectSampleSheet="${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}"
			head -1 "${_sampleSheet}" > "${_projectSampleSheet}.tmp"
			grep "${_project}" "${_sampleSheet}" >> "${_projectSampleSheet}.tmp"
			mv "${_projectSampleSheet}"{.tmp,}
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_projectSampleSheet}."
			#
			# Get pipeline/analysis values from samplesheet.
			#
			IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${_projectSampleSheet}")"
			for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
			do
				_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
			done
			if [[ -n "${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]+isset}" ]]; then
				_pipelineFieldIndex=$((${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]} + 1))
				_projectFieldIndex=$((${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]} + 1))
				readarray -t _pipelines < <(tail -n +2 "${_projectSampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_pipelineFieldIndex}" | sort | uniq )
				if [[ "${#_pipelines[@]}" -lt '1' ]]
				then
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one value in the ${PIPELINECOLUMN} column."
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in samplesheet."
					mv "${_controlFileBaseForFunction}."{started,failed}
					return
				elif [[ "${#_pipelines[@]}" -ge '1' ]]
				then
					for _pipeline in "${_pipelines[@]}"
					do
						
						# Check whether the projectSamplesheet name needs to be without the A,B,C extensions
						
						#
						## create a rawDataCopiedToPrm.finished file to tell the copyProjectDataToPrm that the copying of the rawdata to prm for this project has been finished
						#
						# shellcheck disable=SC2029
						if ssh "${DATA_MANAGER}@${sourceServerFQDN}" "touch ${SCR_ROOT_DIR}/logs/${_project}/run01.rawDataCopiedToPrm.finished"
						then
							log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Succesfully created ${SCR_ROOT_DIR}/logs/${_project}/run01.rawDataCopiedToPrm.finished on ${sourceServerFQDN}"
						else
							log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Could not create ${SCR_ROOT_DIR}/logs/${_project}/run01.rawDataCopiedToPrm.finished on ${sourceServerFQDN}"
							mv "${_controlFileBaseForFunction}."{started,failed}
							return
						fi
					done
				fi
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}, because ${PIPELINECOLUMN} column is missing in samplesheet."
				mv "${_controlFileBaseForFunction}."{started,failed}
				return
			fi	
		fi
	done
	#
	# Track and Trace for flowcell/rawdata.
	#
	local _allProjects
	_allProjects="${_projects[*]}"
	_allProjects="${_allProjects// /,}"
	printf '%s\n' "\"${_allProjects}\"" > "${JOB_CONTROLE_FILE_BASE}.trace_putFromFile_overview.csv" 
	#
	# remove samplesheet on sourceServerFQDN
	#
	# shellcheck disable=SC2029
	if ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "rm \"${SCR_ROOT_DIR}/Samplesheets/${pipeline}/${_run}.${SAMPLESHEET_EXT}\""
	then
		rm -f "${_controlFileBaseForFunction}.failed"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run}.${SAMPLESHEET_EXT} removed from ${SCR_ROOT_DIR}/Samplesheets/${pipeline}/ on ${sourceServerFQDN}."
		mv "${_controlFileBaseForFunction}."{started,finished}
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run}.${SAMPLESHEET_EXT} cannot be removed from ${SCR_ROOT_DIR}/Samplesheets/${pipeline}/ on ${sourceServerFQDN}."
		mv "${_controlFileBaseForFunction}."{started,failed}
	fi
}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished run from tmp to prm storage.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-n	Dry-run: Do not perform actual sync, but only list changes instead.
	-a	Archive mode: only copy the raw data to prm and do not split the flowcell based samplesheet
		into project samplesheets to trigger the project-based analysis of the data with a subsequent pipeline.
	-g	[group]
		Group for which to process data.
	-p	[pipeline]
		from which pipeline is the data coming from (NGS_Demultiplexing, GAP)
	-l	[level]
		Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
	-s	[server]
		Source server address from where the rawdate will be fetched
		Must be a Fully Qualified Domain Name (FQDN).
		E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl
	-r	[root]
		Root dir on the server specified with -s and from where the raw data will be fetched (optional).
		By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
		<group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
		You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
		which is for example the case when fetching data from another group.

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
declare archiveMode='false'
declare group=''
declare dryrun=''
declare sourceServerFQDN=''
declare sourceServerRootDir=''
while getopts ":g:l:s:m:f:r:p:ahn" opt
do
	case "${opt}" in
		a)
			archiveMode='true'
			;;
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		n)
			dryrun='-n'
			;;
		p)
			pipeline="${OPTARG}"
			;;
		m)
			prm_dir="${OPTARG}"
			;;	
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
			;;
		f) finishedPrevStep="${OPTARG}"
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
if [[ -z "${pipeline:-}" ]]
then
	pipeline=''
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'pipeline is not set, default is set to empty string'
fi

if [[ -z "${sourceServerFQDN:-}" ]]
then
log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a Fully Qualified Domain Name (FQDN) for sourceServer with -s.'
fi
if [[ -n "${dryrun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Enabled dryrun option for rsync.'
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
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ -n "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi
if [[ -z "${finishedPrevStep:-}" ]]
then
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Previous step is: ${RAWDATAPROCESSINGFINISHED}"
	mergedSamplesheet='false'
else
	RAWDATAPROCESSINGFINISHED="${finishedPrevStep}"
	mergedSamplesheet='true'
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Previous step is: ${RAWDATAPROCESSINGFINISHED}"
fi

#
# Overrule group's PRM_ROOT_DIR if necessary.
#
if [[ -z "${prm_dir:-}" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "default (${PRM_ROOT_DIR})"
else
	# shellcheck disable=SC2153
	PRM_ROOT_DIR="/groups/${GROUP}/${prm_dir}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "DAT_ROOT_DIR is set to ${PRM_ROOT_DIR}"
	if test -e "/groups/${GROUP}/${prm_dir}/"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_ROOT_DIR} is available"
		
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "${PRM_ROOT_DIR} does not exist, exit!"
	fi
fi

#
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group per combination of ${sourceServer} and ${SCR_ROOT_DIR}.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
# As servernames and folders may contain various characters that would require escaping in (lock) file names,
# we compute a hash for the combination of ${sourceServer} and ${SCR_ROOT_DIR} to append to the ${SCRIPT_NAME}
# for creating unique lock file. We write the combination of ${sourceServer} and ${SCR_ROOT_DIR} in the lock file
# to make it easier to detect which combination of ${sourceServer} and ${SCR_ROOT_DIR} the lock file is for.
#
hashedSource="$(printf '%s:%s' "${sourceServer}" "${SCR_ROOT_DIR}" | md5sum | awk '{print $1}')"
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}_${hashedSource}.lock"
thereShallBeOnlyOne "${lockFile}"

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs ..."

#
# Use multiplexing to reduce the amount of SSH connections created
# when rsyncing using the group's data manager account.
# 
#  1. Become the "${DATA_MANAGER} user who will rsync the data to prm and 
#  2. Add to ~/.ssh/config:
#		ControlMaster auto
#		ControlPath ~/.ssh/tmp/%h_%p_%r
#		ControlPersist 5m
#  3. Create ~/.ssh/tmp dir:
#		mkdir -p -m 700 ~/.ssh/tmp
#  4. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#		chmod -R go-rwx ~/.ssh
#

#
# Get a list of all samplesheets for this group on the specified sourceServer, where the raw data was generated, and
#	1. Loop over their analysis ("run") sub dirs and check if there are any we need to rsync.
#	2. Optionally, split the samplesheets per project after the data was rsynced.
#
declare -a sampleSheetsFromSourceServer
# shellcheck disable=SC2029
readarray -t sampleSheetsFromSourceServer< <(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "find \"${SCR_ROOT_DIR}/Samplesheets/${pipeline}/\" -mindepth 1 -maxdepth 1 -type f -name '*.${SAMPLESHEET_EXT}'")

if [[ "${#sampleSheetsFromSourceServer[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No samplesheets found at ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/${pipeline}/*.${SAMPLESHEET_EXT}."
else
	for sampleSheet in "${sampleSheetsFromSourceServer[@]}"
	do
		#
		# Process this samplesheet / run and find how out how many raw data items it contains.
		#
		filePrefix="$(basename "${sampleSheet%."${SAMPLESHEET_EXT}"}")"
		controlFileBase="${PRM_ROOT_DIR}/logs/${filePrefix}/"
		runPrefix="run01"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}/${runPrefix}.${SCRIPT_NAME}"
		#
		# Determine whether an rsync is required for this run, which is the case when
		# raw data production has finished successfully and this copy script has not.
		#
		if ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" test -e "${SCR_ROOT_DIR}/logs/${filePrefix}/${RAWDATAPROCESSINGFINISHED}"
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/logs/${filePrefix}/${RAWDATAPROCESSINGFINISHED} present."
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/logs/${filePrefix}/${RAWDATAPROCESSINGFINISHED} absent."
			continue
		fi
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${filePrefix}/"
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed run ${filePrefix}."
			continue
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing run ${filePrefix} ..."
		fi
		#
		# Update the column processData (in the overview entity) from the previous step:
		# When data is ready for this step, the previous step must have been completed succesfully.
		# (This is redundant if track and trace worked in the previous step,
		# but catches cases where data was produced correctly, but track and trace failed.)
		#
		printf "finished" > "${JOB_CONTROLE_FILE_BASE}.trace_putFromFile_setProcessRawData.csv"
		#
		# Let's start.
		#
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		# shellcheck disable=SC2174
		mkdir -m 2750 -p "${PRM_ROOT_DIR}/Samplesheets/"
		# shellcheck disable=SC2174
		mkdir -m 2750 -p "${PRM_ROOT_DIR}/Samplesheets/archive/"
		#
		# Step 1: Create a list of raw data items for this run/samplesheet.
		#
		declare -a rawDataItems
		# shellcheck disable=SC2029
		if ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "head -1 \"${sampleSheet}\" | grep 'SentrixBarcode_A'"
		then
			#
			# We are processing array data, which may consist of multiple slides identified by a "SentrixBarcode_A".
			#
			# shellcheck disable=SC2029
			colnum="$(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "head -1 \"${sampleSheet}\" | sed 's/,/\n/g'| nl | grep 'SentrixBarcode_A$' | grep -o '[0-9][0-9]*'")"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found SentrixBarcode_A in column number ${colnum}."
			# shellcheck disable=SC2029
			readarray -t rawDataItems< <(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "tail -n +2 \"${sampleSheet}\" | cut -d , -f \"${colnum}\" | sort | uniq")
		else
			#
			# It must be NGS data consisting of a single flowcell identified by the name of the samplesheet.
			#
			rawDataItems=("${filePrefix}")
		fi
		totalRawDataItems="${#rawDataItems[@]}"
		processedRawDataItems='0'
		#
		# Step 2: Process the raw data items of this samplesheet.
		#
		for rawDataItem in "${rawDataItems[@]}"
		do
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${rawDataItem} ..."
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if ${rawDataItem} is complete and ready to be copied to prm."
			rsyncRuns "${rawDataItem}" "${controlFileBase}/${rawDataItem}"
			if [[ -e "${controlFileBase}/${rawDataItem}.rsyncRuns.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}/${rawDataItem}.rsyncRuns.finished present."
				processedRawDataItems=$((${processedRawDataItems}+1))
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}/${rawDataItem}.rsyncRuns.finished absent -> rsyncRuns failed."
			fi
		done
		#
		# Step 3: Split samplesheet for per project if all raw data items were transferred successfully
		#
		if [[ "${processedRawDataItems}" == "${totalRawDataItems}" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "All raw data items (${processedRawDataItems}/${totalRawDataItems}) were copied to prm."
			splitSamplesheetPerProject "${PRM_ROOT_DIR}/Samplesheets/archive/${filePrefix}.${SAMPLESHEET_EXT}" "${filePrefix}" "${controlFileBase}/${runPrefix}"
		fi
		#
		# Signal success or failure for complete process.
		#
		if [[ -e "${controlFileBase}/${runPrefix}.splitSamplesheetPerProject.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}/${runPrefix}.splitSamplesheetPerProject.finished present."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing ${filePrefix}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}/${runPrefix}.splitSamplesheetPerProject.finished absent -> splitSamplesheetPerProject failed."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process ${filePrefix}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		fi
		
		#
		# Parsing the samplesheet and push samplesheets to the diagnostic cluster if the analysis column is saying so
		#
		
		
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'

trap - EXIT
exit 0

