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
SCRIPT_NAME="$(basename $0 .bash)"
INSTALLATION_DIR=$( cd -P "$( dirname "$0" )" && pwd )
HOSTNAME_SHORT=$(hostname -s)

#
##
### Functions.
##
#
if [[ -f "${INSTALLATION_DIR}/sharedFunctions.bash" && -r "${INSTALLATION_DIR}/sharedFunctions.bash" ]]; then
    . "${INSTALLATION_DIR}/sharedFunctions.bash"
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
    -l   Log level.
         Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

    This script needs 3 config files, which must be located in same location as this script 
    and have the same basename, but suffixed with *.cfg instead of *.sh.
     * <group>.cfg
     * "${HOSTNAME_SHORT}.cfg"
     * sharedConfig.cfg
    In addition the library sharedFunctions.bash is required and this one must be located in the same dir too.
===============================================================================================================


EOH

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
while getopts "g:l:h" opt; do
    case $opt in
        h)
            showHelp
            ;;
        g)
            group="${OPTARG}"
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
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
    "${INSTALLATIONDIR}/${group}.cfg"
    "${INSTALLATIONDIR}/${HOSTNAME_SHORT}.cfg"
    "${INSTALLATIONDIR}/sharedConfig.cfg"
)
for configFile in ${configFiles[@]}; do 
    if [[ -f ${configFile} && -r ${configFile} ]]; then
        log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile}..."
        mixed_stdouterr=$( . ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? "Cannot source ${configFile}."
    else
        log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
    fi
done

#
# Make sure only one copy of this script runs simultaneously 
# per data collection we want to copy to prm -> one copy per group.
# Therefore locking must be done after 
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data trnasfers.
#
lockFile="${LOGDIR}/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${LOGDIR}..."

#
# Load hashdeep.
#
module load hashdeep/${HASHDEEP_VERSION} || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? 'Failed to load hashdeep module.'
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "$(module list)"

#
# Use multiplexing to reduce the amount of SSH connections created.
#


#
# Get a list of all projects for this group and process them.
#
declare -a projects=($(ls -1 "${PROJECTSDIR}"))
for project in ${projects[@]}; do
    LOGGER=${LOGDIR}/${project}/${project}.copyProjectDataToPrm.logger
    #
    # Command to check if projectfolder exists.
    # ToDo: 1. Why do we need this? Rsync will create that dir, right?
    # ToDo: 2. If we need this checkProjectData.sh script, where does it come from? It's not in NGS_Automated...
    #
    makeProjectDataDir=$(ssh ${group}-dm@calculon.hpc.rug.nl "sh ${PROJECTSDIRPRM}/checkProjectData.sh ${PROJECTSDIRPRM} ${project}")
    copyProjectDataDiagnosticsClusterToPrm="${PROJECTSDIR}/${project}/* ${group}-dm@calculon.hpc.rug.nl:${PROJECTSDIRPRM}/${project}"
    
    #
    # ToDo: change $LOGDIR/${project}/${project}.projectDataCopiedToPrm
    #       into   $LOGDIR/${project}/${project}.copyProjectDataToPrm.finished
    #       for consistency with other workflow managment files.
    #       This can then be written as:
    #              $LOGDIR/${project}/${project}.{SCRIPT_NAME}.finished
    #
    if [[ -f $LOGDIR/${project}/${project}.pipeline.finished && ! -f $LOGDIR/${project}/${project}.projectDataCopiedToPrm ]]; then
        
        log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${project}..."
        
        #
        # ToDo: 1. Using ls to count files recursively is dangerous as the result may depend on formatting.
        #          Let's use find instead.
        # ToDo: 2. How to handle multiple run[0-9] subdirs. 
        #          Currently they won't be synced once *.projectDataCopiedToPrm is written.
        
        countFilesProjectDataDirTmp=$(ls -R ${PROJECTSDIR}/${project}/*/results/ | wc -l)
        cd "${PROJECTSDIR}/${project}/"
        if [ ! -f "${project}.allResultmd5sums" ]; then
            md5deep -r -j0 -o f -l */results/ > ${project}.allResultmd5sums
        else
            SIZE=$(cat ${project}.allResultmd5sums | wc -l)
            #
            # ToDo: Fix bug. When md5deep crashed in the middle of creating checksums the list will be incomplete.
            #
            if [ $SIZE -eq 0 ]; then
                md5deep -r -j0 -o f -l */results/ > ${project}.allResultmd5sums
            fi
        fi
        #
        # ToDo: why bother checking for ${makeProjectDataDir}? And not just rsyncing anyway?
        #
        if [ "${makeProjectDataDir}" == "f" ]; then
            echo "copying project data from DiagnosticsCluster to prm" >> ${LOGGER}
            rsync -av --exclude rawdata/ ${copyProjectDataDiagnosticsClusterToPrm} >> $LOGGER
            rsync -av ${PROJECTSDIR}/${project}/${project}.allResultmd5sums ${group}-dm@calculon.hpc.rug.nl:${PROJECTSDIRPRM}/${project}/
            makeProjectDataDir="t"
        fi
        if [ "${makeProjectDataDir}" == "t" ]; then
            #
            # ToDo: Why count files and compare them as opposed to checking the status/result from rsync?
            #       If rsync was Ok -> continue with verification of MD5 checksums.
            #       If rsync was not Ok -> report failure.
            #
            countFilesProjectDataDirPrm=$(ssh ${group}-dm@calculon.hpc.rug.nl "ls -R ${PROJECTSDIRPRM}/${project}/*/results/ | wc -l")
            if [ ${countFilesProjectDataDirTmp} -eq ${countFilesProjectDataDirPrm} ]; then
                echo "${countFilesProjectDataDirTmp} -eq ${countFilesProjectDataDirPrm}"
                COPIEDTOPRM=$(ssh ${group}-dm@calculon.hpc.rug.nl "sh ${PROJECTSDIRPRM}/check.sh ${PROJECTSDIRPRM} ${project}")
                if [[ "${COPIEDTOPRM}" == *"FAILED"* ]]; then
                    echo "md5sum check failed, the copying will start again" >> ${LOGGER}
                    rsync -av --exclude rawdata/ ${copyProjectDataDiagnosticsClusterToPrm} >> $LOGGER 2>&1
                    echo "copy failed" >> $LOGDIR/${project}/${project}.copyProjectDataToPrm.failed
                elif [[ "${COPIEDTOPRM}" == *"PASS"* ]]; then
                    touch $LOGDIR/${project}/${project}.projectDataCopiedToPrm
                    echo "finished copying project data to calculon" >> ${LOGGER}
                printf "De project data voor project ${project} is gekopieerd naar ${PROJECTSDIRPRM}" \
                 | mail -s "project data for project ${project} is copied to permanent storage" ${ONTVANGER}
                    if [ -f $LOGDIR/${project}/${project}.copyProjectDataToPrm.failed ]; then
                        rm $LOGDIR/${project}/${project}.copyProjectDataToPrm.failed
                    fi
                fi
            else
                echo "copying data..." >> $LOGGER
                rsync -av --exclude rawdata/ ${copyProjectDataDiagnosticsClusterToPrm} >> $LOGGER 2>&1
            fi
        fi
    fi
    
    if [ -f $LOGDIR/${project}/${project}.copyProjectDataToPrm.failed ]; then
        COUNT=$(cat $LOGDIR/${project}/${project}.copyProjectDataToPrm.failed | wc -l)
        if [ $COUNT == 10  ]; then
            printf "Verificatie van de MD5 checksums checks voor project ${project} op ${PROJECTSDIRPRM} zijn mislukt: de data is corrupt of incompleet. (De originele data staat op ${HOSTNAME_SHORT}:${PROJECTSDIR}.)" \
             | mail -s "Failed to copy project ${project} to permanent storage." ${ONTVANGER}
        fi
    fi
done

trap - EXIT
exit 0
