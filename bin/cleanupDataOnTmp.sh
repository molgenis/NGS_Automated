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
	-e	Enable email notification. (Disabled by default.)
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
while getopts ":g:l:p:nh" opt; do
	case "${opt}" in
		h)
			showHelp
			;;
		p)
			pipeline="${OPTARG}"
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
if [[ -z "${pipeline:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a pipeline with -p.'
fi
if [[ -n "${dryrun:-}"  ]]; then
	echo -e "\n\t\t #### Enabled dryrun option for cleanup ##### \n"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' '\nEnabled dryrun option for cleanup.\n'
	l4b_log_level="DEBUG"
	l4b_log_level_prio=${l4b_log_levels[${l4b_log_level}]}

else
	dryrun="no"
fi

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

##CLEANING UP PROJECT DATA

mapfile -t projects < <(find "${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/" -maxdepth 1 -mindepth 1 -type d)
if [[ "${#projects[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/."
else
	for project in "${projects[@]}"
	do
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Check for data for which the pipeline was finished at least 10 days ago and will delete the data from ${TMP_ROOT_DIR} ..."
		projectName="$(basename "${project}")" 
		
		# Convert date to seconds for easier calculation of the date difference.
		# 86400 = 1 day in seconds.
		#
		# When the project data is copied to prm, a run01.projectDataCopiedToPrm.finished is created also on tmp
		# If this file is older than 10 days, the project, generatedscripts and tmp data will be deleted
		#
		if [[ -f "${TMP_ROOT_DIR}/logs/${projectName}/run01.projectDataCopiedToPrm.finished" ]]
		then
			dateInSecAnalysisData="$(date -d"$(rsync "${TMP_ROOT_DIR}/logs/${projectName}/run01.projectDataCopiedToPrm.finished" | awk '{print $3}')" +%s)"
	
			dateInSecNow=$(date +%s)
			if [[ $(((dateInSecNow - dateInSecAnalysisData) / 86400)) -gt 10 ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting ${projectName} on tmp because the project data is on prm for at least 10 days"
				rm -v "${TMP_ROOT_DIR}/"{projects,tmp,generatedscripts}"/${pipeline}/${projectName}/"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " the projectDataCopiedToPrm.finished is $(((dateInSecNow - dateInSecAnalysisData) / 86400)) day(s) old. To remove the project,tmp and generatedscripts folders the ${TMP_ROOT_DIR}/logs/${projectName}/run01.projectDataCopiedToPrm.finished needs to be at least 10 days old"
				continue
			fi
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${projectName}/run01.projectDataCopiedToPrm.finished does not exist, skipping"
			continue
		fi
	done
fi
##CLEANING UP RAWDATA 
mapfile -t runs < <(find "${TMP_ROOT_DIAGNOSTICS_DIR}/rawdata/ngs/" -maxdepth 1 -mindepth 1 -type d)
if [[ "${#runs[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found @ ${TMP_ROOT_DIAGNOSTICS_DIR}/rawdata/ngs/."
else
	for run in "${runs[@]}"
	do
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Check for rawdata that is copied to prm at least 7 days ago and will delete the data from ${TMP_ROOT_DIR} ..."
		runName="$(basename "${run}")" 
		
		# Convert date to seconds for easier calculation of the date difference.
		# 86400 = 1 day in seconds.
		#
		# When the project data is copied to prm, a run01.RawDataCopiedToPrm.finished is created also on tmp
		# If this file is older than 10 days, the project, generatedscripts and tmp data will be deleted
		#
		if [[ -f "${TMP_ROOT_DIR}/logs/${run}/run01.rawDataCopiedToPrm.finished" ]]
		then
			dateInSecAnalysisData="$(date -d"$(rsync "${TMP_ROOT_DIR}/logs/${runName}/run01.rawDataCopiedToPrm.finished" | awk '{print $3}')" +%s)"
	
			dateInSecNow=$(date +%s)
			if [[ $(((dateInSecNow - dateInSecAnalysisData) / 86400)) -gt 10 ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting ${runName} on tmp because the rawdata is on prm for at least 7 days"
				rm -v "${TMP_ROOT_DIR}/rawdata/ngs/${runName}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " the rawDataCopiedToPrm is $(((dateInSecNow - dateInSecAnalysisData) / 86400)) day(s) old. To remove rawdata/ngs folder the ${TMP_ROOT_DIR}/logs/${run}/run01.rawDataCopiedToPrm.finished needs to be at least 7 days old"
				continue
			fi
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${runName}/run01.rawDataCopiedToPrm.finished does not exist, skipping"
			continue
		fi
	done
fi


##CLEANING UP GAVIN RUNS
HOMEDIRGAVIN="${TMP_ROOT_DIR}/GavinStandAlone/"

if [[ -d "${HOMEDIRGAVIN}" ]]
then
	find "${HOMEDIRGAVIN}/input/" -name '*.cleaned' -type f -mtime +7 -exec rm -- {} \;
	if ls "${HOMEDIRGAVIN}/input/"*.vcf.finished 1> /dev/null 2>&1
	then
		finishedFiles="$(find "${HOMEDIRGAVIN}/input/"*.vcf.finished -type f)"
		for i in "${finishedFiles[@]}"
		do
			fileName=$(basename "${i}")
			name=${fileName%%.*}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting ${TMP_ROOT_DIR}/tmp/NGS_DNA/Gavin_${name}/"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "     and ${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/Gavin_${name}"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "     and ${TMP_ROOT_DIR}/projects/NGS_DNA/Gavin_${name}/"
			if [[ "${dryrun}" == "no" ]]
			then
				rm -rf "${TMP_ROOT_DIR}/tmp/NGS_DNA/Gavin_${name}/"
				rm -rf "${TMP_ROOT_DIR}/generatedscripts//NGS_DNA/Gavin_${name}/"
				rm -rf "${TMP_ROOT_DIR}/projects/NGS_DNA/Gavin_${name}/"
				touch "${i}.cleaned"
			fi
		done
	fi
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
	"no GavinStandAlone found, skipped"
fi


log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0