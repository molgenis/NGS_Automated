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

#
##
### Functions.
##
#
if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]; then
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
Script to check the status of the pipeline and emails notification

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g	Group.
	-n	Dry-run: Do not perform actual removal, but only print the remove commands instead.
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
declare dryrun=''
while getopts ":g:l:nh" opt; do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		n)
			dryrun='-n'
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
if [[ -z "${group:-}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -n "${dryrun:-}"  ]]; then
	echo -e "\n\t\t #### Enabled dryrun option for cleanup ##### \n"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' '\nEnabled dryrun option for cleanup.\n'
	l4b_log_level="DEBUG"
	l4b_log_level_prio=${l4b_log_levels[${l4b_log_level}]}

else
	dryrun="no"
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "dryrun=${dryrun}"

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
)
for configFile in "${configFiles[@]}"; do
	if [[ -f "${configFile}" && -r "${configFile}" ]]; then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile} ..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		# Disable shellcheck code syntax checking for config files.
		# shellcheck source=/dev/null
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Cannot source ${configFile}."
		# shellcheck source=/dev/null
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done



mapfile -t rawdatasamplesheets < <(ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "find \"${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/NGS_Demultiplexing/\" -maxdepth 1 -mindepth 1 -type f")
if [[ "${#rawdatasamplesheets[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No rawdatasamplesheets files found @ ${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/NGS_Demultiplexing."
	exit
else
	for rawdatasamplesheet in "${rawdatasamplesheets[@]}"
	do
		rawdatasamplesheet=$(basename "${rawdatasamplesheet}" .csv)
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${rawdatasamplesheet} on ${TMP_ROOT_DIAGNOSTICS_DIR}, check if it is present on ${PRM_ROOT_DIR}"

		for prm_dir in "${ALL_PRM[@]}"
		do
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "looping through ${prm_dir}"
			
			export PRM_ROOT_DIR="/groups/${group}/${prm_dir}/"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "PRM_ROOT_DIR=${PRM_ROOT_DIR}"
			if [[ -e "${PRM_ROOT_DIR}/rawdata/${PRMRAWDATA}/${rawdatasamplesheet}/" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Great, the rawdata of ${rawdatasamplesheet} is already processed and stored on ${PRM_ROOT_DIR}"
				if [[ "${dryrun}"=="no" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "time to remove the extra samplesheets from ${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/NGS_Demultiplexing/"
					ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "rm \"${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/NGS_Demultiplexing/${rawdatasamplesheet}\".csv"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "ssh ${DATA_MANAGER}@${HOSTNAME_TMP} rm ${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/NGS_Demultiplexing/${rawdatasamplesheet}.csv"
				fi
			else
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${rawdatasamplesheet} is not stored on ${prm_dir}, check the other prms and leave the samplesheet for now"
			fi
		done
	done
fi

