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
while getopts ":g:l:h" opt; do
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
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"

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

mapfile -t projects < <(find "${TMP_ROOT_DIR}/runs/AGCT/" -maxdepth 1 -mindepth 1 -type d -name "*batch*")
if [[ "${#projects[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIR}/runs/AGCT/."
else
	for project in "${projects[@]}"
	do
		originalproject=$(basename "${project}")
		project="${originalproject}_plusGDIO"
		logDir="${TMP_ROOT_DIR}/logs/${project}/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${logDir}"
		controlFileBase="${logDir}/run01"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]] 
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${project}."
			continue
		fi
		
		#check if pipeline is finished
		if [[ -f "${TMP_ROOT_DIR}/logs/${originalproject}/run01.arrayConversion.finished" ]]
		then

			printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
			declare -a _sampleSheetColumnNames=()
			declare -A _sampleSheetColumnOffsets=()

			IFS="," read -r -a _sampleSheetColumnNames <<< "$(head -1 "${TMP_ROOT_DIR}/Samplesheets/PGx/${originalproject}.csv")"
			for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
			do
				_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
			done
		
			_sentrixBarcodeFieldIndex=""
			if [[ -n "${_sampleSheetColumnOffsets["SentrixBarcode_A"]+isset}" ]]; 
			then
				_sentrixBarcodeFieldIndex=$((${_sampleSheetColumnOffsets["SentrixBarcode_A"]} + 1))
			fi
		
			mapfile -t sentrixBarcodes< <(awk -v s="${_sentrixBarcodeFieldIndex}" 'BEGIN {FS=","}{if (NR>1){print $s}}' "${TMP_ROOT_DIR}/Samplesheets/PGx/${originalproject}.csv" | sort -V  | uniq)
		
			if [[ "${#sentrixBarcodes[@]}" -eq '0' ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "There are no sentrixBarcodes in the samplesheet!"
				continue
			else
				module load PGx
				for sentrixBarcode in "${sentrixBarcodes[@]}"
				do
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copying ${sentrixBarcode} to ${TMP_ROOT_DIR}/rawdata/gtc/"
					rsync -rv "/groups/umcg-pgx/${TMP_LFS}/rawdata/array/GTC/${sentrixBarcode}" "${TMP_ROOT_DIR}/rawdata/gtc/"
				done
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "running ${EBROOTPGX}/pgx_pre_preprocess.sh -p ${originalproject}"
				bash "${EBROOTPGX}/pgx_pre_preprocess.sh" -p "${originalproject}" \
				|| {
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" "0" "pipeline crashed: ${EBROOTPGX}/pgx_pre_preprocess.sh -p ${originalproject}"
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" "0" "logs can be found here: ${JOB_CONTROLE_FILE_BASE}.failed"
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				continue
				}
				rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
				mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
			fi
		fi
	done
fi

#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0
