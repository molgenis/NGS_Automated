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
SCRIPT_NAME="$(basename ${0} .bash)"
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

function rsyncProject() {
    local _project="${1}"
    log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${_project}..."
    
    cd "${TMP_ROOT_DIR}/projects/${_project}/" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? "Cannot access ${TMP_ROOT_DIR}/projects/${_project}/."
    
    #
    # Get a list of analysis ("run") sub dirs for this project 
    # and loop over them to see if there are any we need to rsync.
    #
    local -a _runs=($(find "./" -maxdepth 1 -mindepth 1 -type d))
    local run
    for _run in "${_runs[@]}"; do
        
        log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run}..."
        local _log_file="${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.log"
        
        #
        # Determine whether an rsync is required for this run, which is the case when
        #  1. either the pipeline has finished and this copy script has not
        #  2. or when a pipeline has updated the results after previous execution of this copy script. 
        #
        # Temporarily check for "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished"
        #        in addition to "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished"
        # for backwards compatibility with old NGS_Automated 1.x.
        #
        local _rsyncRequired='false'
        if [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished" || -f "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished" ]]; then
            if [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished" ]]; then
                local _pipelineFinished="${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished"
            else
                local _pipelineFinished="${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished"
            fi
            log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_pipelineFinished}..."
            if [[ ! -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.finished" ]]; then
                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.finished present."
                _rsyncRequired='true'
            elif [[ "${_pipelineFinished}" -nt "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.finished" ]]; then
                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*.pipeline.finished newer than *.${SCRIPT_NAME}.finished."
                _rsyncRequired='true'
            fi
        fi
        log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsync required = ${_rsyncRequired}."
        if [[ "${_rsyncRequired}" == 'false' ]]; then
            log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_project}/${_run}."
            continue
        fi
        
        #
        # Count the number of all files produced in this analysis run.
        #
        _countFilesProjectRunDirTmp=$(find "./${_run}/" -type f | wc -l)
        
        #
        # Recursively create a list of MD5 checksums unless it is 
        #  1. already present, 
        #  2. and complete,
        #  3. and up-to-date.
        #
        local _checksumsAvailable='false'
        if [ -f "${_run}.md5" ]; then
            if [[ ${_pipelineFinished} -ot "${_run}.md5" ]]; then
                local _countFilesProjectRunChecksumFileTmp=$(wc -l "${_run}.md5")
                if [[ "${_countFilesProjectRunChecksumFileTmp}" -eq "${_countFilesProjectRunDirTmp}" ]]; then
                    _checksumsAvailable='true'
                fi
            fi
        fi
        log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "md5deep checksums already present = ${_checksumsAvailable}."
        if [[ "${_checksumsAvailable}" == 'false' ]]; then
            log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Computing MD5 checksums with md5deep for ${_project}/${_run}/..."
            md5deep -r -j0 -o f -l */ > "${_run}.md5" 2>> "${_log_file}" \
              || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? "Cannot compute checksums with md5deep. See ${_log_file} for details."
        fi
        
        #
        # Perform rsync.
        #  1. For ${_run} dir: recursively with "default" archive (-a),
        #     which checks for differences based on file size and modification times.
        #     No need to use checksums here as we will verify checksums later anyway.
        #  2. For ${_run}.md5 list of checksums with archive (-a) and -c to determine 
        #     differences based on checksum instead of file size and modification time.
        #     It is vitally important (and computationally cheap) to make sure 
        #     the list of checksums is complete and up-to-date!
        #
        # ToDo: Do we need to add --delete to get rid of files that should no longer be there 
        #       if an analysis run got updated?
        #
        local _transferSoFarSoGood='true'
        log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run} dir..."
        rsync -av ${dryrun:-} \
                   "${TMP_ROOT_DIR}/projects/${_project}/${_run}" \
                   "${DATA_MANAGER}@${HOSTNAME_PRM}:${PRM_ROOT_DIR}/projects/${_project}/" \
                >> "${_log_file}" 2>&1 \
         || {
             log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" $? "Failed to rsync ${TMP_ROOT_DIR}/projects/${_project}/${_run} dir. See ${_log_file} for details."
             echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_log_file} for details." \
               >> "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed"
             _transferSoFarSoGood='false'
            }
        
        log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run}.md5 checksums..."
        rsync -acv ${dryrun:-} \
                   "${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5" \
                   "${DATA_MANAGER}@${HOSTNAME_PRM}:${PRM_ROOT_DIR}/projects/${_project}/" \
                >> "${_log_file}" 2>&1 \
         || {
              log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" $? "Failed to rsync ${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5. See ${_log_file} for details."
              echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_log_file} for details." \
                >> "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed"
             _transferSoFarSoGood='false'
            }
        
        #
        # Sanity check.
        #
        #  1. Firstly do a quick count of the amount of files to make sure we are complete.
        #     (No need to waist a lot of time on computing checksums for a partially failed transfer).
        #  2. Secondly verify checksums on the destination.
        #
        if [[ ${_transferSoFarSoGood} == 'true' ]]; then
            local _countFilesProjectDataDirPrm=$(ssh ${DATA_MANAGER}@${HOSTNAME_PRM} "find ${PRM_ROOT_DIR}/projects/${_project}/${_run}/ -type f | wc -l")
            if [[ ${_countFilesProjectDataDirTmp} -ne ${_countFilesProjectDataDirPrm} ]]; then
                echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectDataDirTmp}) and prm (${_countFilesProjectDataDirPrm}) is NOT the same!" \
                      >> "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed"
                log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
                         "Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectDataDirTmp}) and prm (${_countFilesProjectDataDirPrm}) is NOT the same!"
            else
                log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
                         "Amount of files on tmp and prm is the same for ${_project}/${_run}: ${_countFilesProjectDataDirPrm}."
                #
                # Verify checksums on prm storage.
                #
                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
                         "Started verification of checksums by ${DATA_MANAGER}@${HOSTNAME_PRM} using checksums from ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5."
                local _checksumVerification=$(ssh ${DATA_MANAGER}@${HOSTNAME_PRM} "\
                        cd ${PRM_ROOT_DIR}/projects/${_project}; \
                        if [ md5sum -c ${_run}.md5 > ${_run}.md5.log 2>&1 ]; then \
                            echo 'PASS' \
                        else \
                            echo 'FAILED' \
                        fi \
                    ")
                if [[ "${_checksumVerification}" == 'FAILED' ]]; then
                    echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
                      >> "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed"
                    log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details."
                elif [[ "${_checksumVerification}" == 'PASS' ]]; then
                    echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
                      >> "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed" \
                      && mv "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.{failed,finished}"
                    log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
                else
                    log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Got unexpected result from checksum verification:'
                    log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected FAILED or PASS, but got: ${_checksumVerification}."
                fi
            fi
        fi
        
        #
        # Send e-mail notification.
        #
        if [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed" \
              &&  $(wc -l "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed") -ge 10 \
              && ! -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed.mailed" ]]; then
            if [[ ${email} == 'true' ]]; then
                printf '%s\n%s\n' \
                       "Verificatie van de MD5 checksums checks voor project ${_project}/${_run} in ${PRM_ROOT_DIR}/projects/ is mislukt:" \
                       "De data is corrupt of incompleet. De originele data staat in ${HOSTNAME_SHORT}:${TMP_ROOT_DIR}/projects/." \
                 | mail -s "Failed to copy project ${_project}/${_run} to permanent storage." "${EMAIL_TO}"
                touch   "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed.mailed"
            else
                log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Verificatie van de MD5 checksums checks voor project ${_project}/${_run} in ${PRM_ROOT_DIR}/projects/ is mislukt:"
                log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    De data is corrupt of incompleet. De originele data staat in ${HOSTNAME_SHORT}:${TMP_ROOT_DIR}/projects/."
            fi
        elif [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.finished" ]]; then
            if [[ ${email} == 'true' ]]; then
                printf '%s\n' \
                       "De data voor project ${_project}/${_run} is klaar en beschikbaar in ${PRM_ROOT_DIR}/projects/." \
                 | mail -s "Project ${_project}/${_run} was successfully copied to permanent storage." "${EMAIL_TO}"
                touch   "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.failed.mailed" \
                 && mv "${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.{failed,finished}.mailed"
             else
                 log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "De data voor project ${_project}/${_run} is klaar en beschikbaar in ${PRM_ROOT_DIR}/projects/."
             fi
        else
            log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Ended up in unexpected state:'
            log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected either ${SCRIPT_NAME}.finished or ${SCRIPT_NAME}.failed, but both files are absent."
        fi
    done
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
        e)
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
# Check for mandatory options.
#
if [[ -z "${group:-}" ]]; then
    log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
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
        mixed_stdouterr=$( source ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? "Cannot source ${configFile}."
        source ${configFile}  # May seem redundant, but is a mandatory workaround for some Bash versions.
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
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."

#
# Load hashdeep.
#
module load hashdeep/${HASHDEEP_VERSION} || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? 'Failed to load hashdeep module.'
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "$(module list)"

#
# Use multiplexing to reduce the amount of SSH connections created.
# 
#  1. Add to ~/.ssh/config of the data manager account used to copy data to prm:
#        ControlMaster auto
#        ControlPath ~/.ssh/tmp/%h_%p_%r
#        ControlPersist 5m
#  2. Create ~/.ssh/tmp dir for the data manager account used to copy data to prm:
#        mkdir -p -m 700 ~/.ssh/tmp
#        chmod -R go-rwx ~/.ssh
#  3. Open one SSH connection here before looping over the projects.
#

#
# Get a list of all projects for this group and process them.
#
declare -a projects=($(ls -1 "${TMP_ROOT_DIR}/projects"))
for project in "${projects[@]}"; do
    rsyncProject "${project}"
done

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0
