#!/bin/bash

# executed by the umcg-gd-ateambot, part of the NGS_Automated.


if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.

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
======================================================================================================================
Scripts to make automatically a samplesheet for the concordance check between ngs and array data.
ngs.vcf should be in /groups/${NGSGROUP}/${PRM_LFS}/concordance/ngs/.
array.vcf should be in /groups/${ARRAYGROUP}/${PRM_LFS}/concordance/array/.


Usage:

	$(basename "${0}") OPTIONS

Options:

	-h   Show this help.
	-g   ngsgroup (the group which runs the script and countains the ngs.vcf files, umcg-gd).
	-a   arraygroup (the group where the array.vcf files are, umcg-gap )
	-l   Log level.
	     Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg     for the group specified with -g
		2. <host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
		3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.

======================================================================================================================

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
while getopts "g:a:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			NGSGROUP="${OPTARG}"
			;;
		a)
			ARRAYGROUP="${OPTARG}"
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
			;;	esac
done

#
# Check commandline options.
#
if [[ -z "${NGSGROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a ngs-group with -g. For the ngs.vcf files'
fi

if [[ -z "${ARRAYGROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify an array-group with -a. for the array.vcf files'
fi
#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${NGSGROUP}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${CFG_DIR}/ConcordanceCheck.cfg"
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
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#

if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi


module load "${htsLibVersion}"
module load "${bedToolsVersion}"
module list

concordanceDir="/groups/${NGSGROUP}/${TMP_LFS}/concordance/"
ngsVcfDirPRM="/groups/${NGSGROUP}/prm0*/concordance/ngs/"
arrayVcfDirPRM="/groups/${ARRAYGROUP}/${PRM_LFS}/concordance/array/"

for vcfFile in $(ssh "${HOSTNAME_PRM}" "find ${ngsVcfDirPRM} \( -type f -o -type l \) -name *final.vcf.gz")
do

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "processing ngs-vcf ${vcfFile}"
	ngsVcfId=$(basename "${vcfFile}" ".final.vcf.gz")
	if ssh "${HOSTNAME_PRM}" "zcat ${vcfFile} | grep \"##FastQ_Barcode=\""
	then
		ngsBarcodeTmp=$(ssh "${HOSTNAME_PRM}" "zcat ${vcfFile} | grep \"##FastQ_Barcode=\"")
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "ngsBarcodeTmp=${ngsBarcodeTmp}"

		ngsBarcode=$(echo "${ngsBarcodeTmp}" | awk 'BEGIN {FS="="}{print "_"$2}')
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "ngsBarcode=${ngsBarcode}"
	else
		ngsBarcode=""
	fi

	ngsInfo=$(echo "${ngsVcfId}" | awk 'BEGIN {FS="_"}{OFS="_"}{print $3,$4,$5}')
	ngsInfoList=$(echo "${ngsInfo}${ngsBarcode}")

	dnaNo=$(echo "${ngsVcfId}" | awk 'BEGIN {FS="_"}{print substr($3,4)}')

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "info from ngs.vcf: ${ngsInfoList}"

	checkArrayVcf=$(ssh "${HOSTNAME_PRM}" "find ${arrayVcfDirPRM} \( -type f -o -type l \) -name '*DNA-"${dnaNo}"_*.FINAL.vcf' ")

	copyArrayFile="false"
	cluster=""
	if [[ -z "${checkArrayVcf}" ]]
	then
	##
	#### Make part that is also looking on the ISILON storage cluster
	##
		#for otherPRM in ${ARRAY_OTHER_PRM_LFS_ISILON[@]}
		#do
		#	checkArrayVcf=$(ssh ${HOSTNAMEPRM_ISOLON} "find /groups/${ARRAYGROUP}/${otherPRM}/concordance/array/ -type f -o -type l -iname DNA-${dnaNo}_*.FINAL.vcf")

		#done
		#if [[ -z "${checkArrayVcf}" ]]
		#then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "there is not (yet) an array vcf file present for ${ngsVcfId}"
		continue
		#else
			#copyArrayFile="true"
		#fi
	else
		copyArrayFile="true"
		cluster="${HOSTNAME_PRM}"
	fi

	if [ "${copyArrayFile}" == "true" ]
	then
		#rsync --copy-links ${HOSTNAME_PRM}:${arrayVcfDirPRM}/DNA-${dnaNo}_*.FINAL.vcf "${concordanceDir}/array/"
		echo "cluster: ${cluster}"
		arrayFile=$(ssh ${cluster} "ls -1 ${arrayVcfDirPRM}/DNA-${dnaNo}_*.FINAL.vcf")
		echo "--------- ${arrayFile}"
		arrayId="$(basename "${arrayFile}" .FINAL.vcf)"
		arrayInfoList=$(echo "${arrayId}" | awk 'BEGIN {FS="_"}{OFS="_"}{print $1,$2,$3,$5,$6}')
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "processing array vcf ${arrayFile}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "info from array.vcf: ${arrayInfoList}"

	fi
	if [ -f "${concordanceDir}/logs/${arrayInfoList}_${ngsInfoList}.ConcordanceCheck.finished" ]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "the concordance between ${arrayInfoList} ${ngsInfoList} is being calculated"
		continue
	else
		echo -e "data1Id\tdata2Id\tlocation1\tlocation2\n${arrayId}\t${ngsVcfId}\t${HOSTNAME_PRM}:${arrayVcfDirPRM}/${arrayId}.FINAL.vcf\t${HOSTNAME_PRM}:${ngsVcfDirPRM}/${ngsVcfId}.final.vcf.gz" > "${concordanceDir}/samplesheets/${arrayInfoList}_${ngsInfoList}.sampleId.txt"
	fi 

done

trap - EXIT
exit 0



