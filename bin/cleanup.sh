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
Script to check the status of the pipeline and emails notification
Usage:
	$(basename $0) OPTIONS
Options:
	-h   Show this help.
	-g   Group.
	-n   Dry-run: Do not perform actual removal, but only print the remove commands instead.
	-e   Enable email notification. (Disabled by default.)
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
##
### Main.
##
#


#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
declare dryrun=''
while getopts "g:l:nh" opt; do
	case $opt in
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


HOMEDIRGAVIN="${TMP_ROOT_DIR}/GavinStandAlone/"

if [ -d "${HOMEDIRGAVIN}" ]
then
	find "${HOMEDIRGAVIN}/input/" -name *.cleaned -type f -mtime +7 -exec rm {} \;
	if ls ${HOMEDIRGAVIN}/input/*.vcf.finished 1> /dev/null 2>&1
	then
		for i in $(ls ${HOMEDIRGAVIN}/input/*.vcf.finished)
		do
			fileName=$(basename "${i}")
			name=${fileName%%.*}

			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"rm -rf ${TMP_ROOT_DIR}/tmp/Gavin_${name}/ \nrm -rf ${TMP_ROOT_DIR}/generatedscripts/Gavin_${name}\nrm -rf ${TMP_ROOT_DIR}/projects/Gavin_${name}/"
			if [ "${dryrun}" == "no" ]
			then
				rm -rf "${TMP_ROOT_DIR}/tmp/Gavin_${name}/"
				rm -rf "${TMP_ROOT_DIR}/generatedscripts/Gavin_${name}/"
				rm -rf "${TMP_ROOT_DIR}/projects/Gavin_${name}/"

				touch "${i}.cleaned"
			fi
		done
	fi
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
	"no GavinStandAlone found, skipped"
fi

##cleaning up files older than 30 days in PROJECTS and TMP when files are copied

for i in $(find "${TMP_ROOT_DIR}/projects/" -maxdepth 1 -type d -mtime +30 -exec ls -d {} \;)
do
	project=$(basename $i)
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
	"check ${project}"
	if [ -f "${TMP_ROOT_DIR}/logs/${project}/${project}.projectDataCopiedToPrm" ]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"rm -rf ${GROUP_HOME}/projects/${project}/ \nrm -rf ${GROUP_HOME}/tmp/${project}/"

		if [ "${dryrun}" == "no" ]
		then
			rm -rf "${GROUP_HOME}/projects/${project}"
			rm -rf "${GROUP_HOME}/tmp/${project}"
		fi

	fi
done
##cleaning up files older than 30 days in RAWDATA when files are copied
for i in $(find "${TMP_ROOT_DIR}/rawdata/ngs/" -maxdepth 1 -type d -mtime +30 -exec ls -d {} \;) 
do
	run=$(basename $i)

	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
	"check ${run}"

	if [ -f "${TMP_ROOT_DIR}/logs/${run}/${run}.dataCopiedToPrm" ]
        then
		countPrm=$(ssh calculon.hpc.rug.nl "ls ${PRM_ROOT_DIR}/rawdata/ngs/${run}/${run}*.fq.gz* | wc -l")
		countTmp=$(ls ${TMP_ROOT_DIR}/rawdata/ngs/${run}/${run}*.fq.gz* | wc -l)
		if [ "${countPrm}" == "${countTmp}" ]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"rm -rf ${TMP_ROOT_DIR}/rawdata/ngs/${run}"

			if [ "${dryrun}" == "no" ]
                        then
				rm -rf "${TMP_ROOT_DIR}/rawdata/ngs/${run}"
			fi
		fi
        fi
done

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0
