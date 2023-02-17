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
function splitPerProject(){
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

	if [[ "${archiveSamplesheet}" == 'true' ]]
	then
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
	fi
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
	# Check if the samplesheet needs to be splitted
	#
	_pipelineFieldIndex=$((${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]} + 1))
	readarray -t valueInSamplesheet < <(tail -n +2 "${samplesheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_pipelineFieldIndex}" | sort | uniq )
	if [[ "${valueInSamplesheet[0]}" != *"NGS_DNA"*  && "${valueInSamplesheet[0]}" != *"GAP"* ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "There is no next step detected in the samplesheet, no need to continue splitting"
		continue
	elif [[ "${valueInSamplesheet[0]}" == *"NGS_DNA"* ]]
	then 
		nextStep='NGS_DNA'
	elif [[ "${valueInSamplesheet[0]}" == *"GAP"* ]]
	then
		nextStep='GAP'
	fi
	
	if [[ -n "${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]+isset}" ]]
	then
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

		local _projectSampleSheet
		_projectSampleSheet="${TMP_ROOT_DIR}/Samplesheets/${nextStep}/${_project}.${SAMPLESHEET_EXT}"
		head -1 "${_sampleSheet}" > "${_projectSampleSheet}.tmp"
		grep "${_project}" "${_sampleSheet}" >> "${_projectSampleSheet}.tmp"
		mv "${_projectSampleSheet}"{.tmp,}
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_projectSampleSheet}."

	fi
done

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
	-s	archive samplesheet on prm
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
declare group=''

while getopts ":g:l:hs" opt
do
	case "${opt}" in

		h)
			showHelp
			;;
		s)
			archiveSamplesheet='true'
			;;
		g)
			group="${OPTARG}"
			;;
		p)
			pipeline="${OPTARG}"
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
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '1' 'No pipeline specified, default is NGS_Demultiplexing'
	pipeline="NGS_Demultiplexing"
fi
if [[ -z "${archiveSamplesheet:}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'no archiving of samplesheet'
	archiveSamplesheet='false'
else
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'enabled archiving of samplesheet'
fi
#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
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
if [[ -n "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi

#
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

hashedSource="$(printf '%s:%s' "${sourceServer}" "${SCR_ROOT_DIR}" | md5sum | awk '{print $1}')"
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}_${hashedSource}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs ..."

declare -a sampleSheets
# shellcheck disable=SC2029
readarray -t sampleSheets< <(find "\"${SCR_ROOT_DIR}/Samplesheets/${pipeline}/\" -mindepth 1 -maxdepth 1 -type f -name '*.${SAMPLESHEET_EXT}'")

if [[ "${#sampleSheets[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No samplesheets found at ${SCR_ROOT_DIR}/Samplesheets/${pipeline}/*.${SAMPLESHEET_EXT}."
else
	for sampleSheet in "${sampleSheets[@]}"
	do
		filePrefix="$(basename "${sampleSheet%."${SAMPLESHEET_EXT}"}")"
		# THIS HAS TO CHANGE IF WE WANT TO REUSE THIS SCRIPT ON PRM
		controlFileBase="${TMP_ROOT_DIR}/logs/${filePrefix}/"
		splitPerProject "${sampleSheet}" "${filePrefix}" "${controlFileBase}/run01"
		
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
printf '%s\n' "Finished." >> "${lockFile}"

trap - EXIT
exit 0

