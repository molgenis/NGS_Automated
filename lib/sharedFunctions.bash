#
##
### Generic BASH functions for error handling and logging.
##
#

#
# Custom signal trapping functions (one for each signal) required to format log lines depending on signal.
#
function trapSig() {
    local _trap_function="${1}"
    local _line="${2}"
    local _function="${3}"
    local _status="${4}"
    shift 4
    for _sig; do
        trap "${_trap_function} ${_sig} ${_line} ${_function} ${_status}" "${_sig}"
    done
}

function trapHandler() {
    local _signal="${1}"
    local _line="${2}"
    local _function="${3}"
    local _status="${4}"
    log4Bash 'FATAL' "${_line}" "${_function}" "${_status}" "Trapped ${_signal} signal."
}

#
# Trap all exit signals: HUP(1), INT(2), QUIT(3), TERM(15), ERR.
#
trapSig 'trapHandler' '${LINENO}' '${FUNCNAME:-main}' '$?' HUP INT QUIT TERM EXIT ERR

#
# Catch all function for logging using log levels like in Log4j.
#
# Requires 5 ARGS:
#  1. log_level     Defined explicitly by programmer.
#  2. ${LINENO}     Bash env var indicating the active line number in the excuting script.
#  3. ${FUNCNAME}   Bash env var indicating the active function in the excuting script.
#  4. (Exit) STATUS Either defined explicitly by programmer or use Bash env var $? for the exit status of the last command.
#  5  log_message   Defined explicitly by programmer.
#
# When log_level == FATAL the script will be terminated.
#
# Example of debug log line (should use EXIT_STATUS = 0 = 'OK'):
#    log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'We managed to get this far.'
#
# Example of FATAL error with explicit exit status 1 defined by the script: 
#    log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" 1 'We cannot continue because of ....'
#
# Example of executing a command and logging failure with the EXIT_STATUS of that command (= $?):
#    someCommand || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? 'Failed to execute someCommand.'
#
function log4Bash() {
    #
    # Validate params.
    #
    if [ ! ${#} -eq 5 ] ;then
        echo "WARN: should have passed 5 arguments to ${FUNCNAME}: log_level, LINENO, FUNCNAME, (Exit) STATUS and log_message."
    fi
    
    #
    # Determine prio.
    #
    local _log_level="${1}"
    local _log_level_prio=${l4b_log_levels[$_log_level]}
    local _status="${4:-$?}"
    
    #
    # Log message if prio exceeds threshold.
    #
    if [ ${_log_level_prio} -ge ${l4b_log_level_prio} ]; then
        local _problematic_line="${2:-'?'}"
        local _problematic_function="${3:-'main'}"
        local _log_message="${5:-'No custom message.'}"
        
        #
        # Some signals erroneously report $LINENO = 1,
        # but that line contains the shebang and cannot be the one causing problems.
        #
        if [ "${_problematic_line}" -eq 1 ]; then
            _problematic_line='?'
        fi
        
        #
        # Format message.
        #
        local _log_timestamp=$(date "+%Y-%m-%dT%H:%M:%S") # Creates ISO 8601 compatible timestamp.
        local _log_line_prefix=$(printf "%-s %-s %-5s @ L%-s(%-s)>" "${SCRIPT_NAME}" "${_log_timestamp}" "${_log_level}" "${_problematic_line}" "${_problematic_function}")
        local _log_line="${_log_line_prefix} ${_log_message}"
        if [ ! -z "${mixed_stdouterr:-}" ]; then
            _log_line="${_log_line} STD[OUT+ERR]: ${mixed_stdouterr}"
        fi
        if [ ${_status} -ne 0 ]; then
            _log_line="${_log_line} (Exit status = ${_status})"
        fi
        
        #
        # Log to STDOUT (low prio <= 'WARN') or STDERR (high prio >= 'ERROR').
        #
        if [[ ${_log_level_prio} -ge ${l4b_log_levels['ERROR']} || ${_status} -ne 0 ]]; then
            printf '%s\n' "${_log_line}" > /dev/stderr
        else
            printf '%s\n' "${_log_line}"
        fi
    fi
    
    #
    # Exit if this was a FATAL error.
    #
    if [ ${_log_level_prio} -ge ${l4b_log_levels['FATAL']} ]; then
        #
        # Reset trap and exit.
        #
        trap - EXIT
        if [ ${_status} -ne 0 ]; then
            exit ${_status}
        else
            exit 1
        fi
    fi
}

#
# Initialise Log4Bash logging with defaults.
#
l4b_log_level="${log_level:-INFO}"
declare -A l4b_log_levels=(
    ['TRACE']='0'
    ['DEBUG']='1'
    ['INFO']='2'
    ['WARN']='3'
    ['ERROR']='4'
    ['FATAL']='5'
)
l4b_log_level_prio="${l4b_log_levels[${l4b_log_level}]}"
mixed_stdouterr='' # global variable to capture output from commands for reporting in custom log messages.

#
# Lock function using flock and a file descriptor (FD).
# This uses FD 200 as per flock manpage example.
#
function thereShallBeOnlyOne() {
    local _lock_file="${1}"
    exec 200>"${_lock_file}" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? "Failed to create FD 200>${_lock_file} for locking."
    if [ ! flock -n 200 ]; then
        log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '1' "Lockfile ${_lock_file} already claimed by another instance of $(basename ${0})."
        log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Another instance is already running and there shall be only one.'
        # No need for explicit exit here: log4Bash with log level FATAL will make sure we exit.
    fi
}

