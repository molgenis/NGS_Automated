#!/bin/bash

set -e
set -u
set -o pipefail

#
# Disable some shellcheck warnings:
#  * SC2004: $/${} is unnecessary on arithmetic variables.
#            But for consistency we prefer to always use ${} anyway.
#  * SC2015: Note that A && B || C is not if-then-else. C may run when A is true.
#            We know and use this construct regularly to create "transactions"
#            where C is only executed when both A and B have succeeded.
#
export SHELLCHECK_OPTS="-e SC2004 -e SC2015"

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script for sanity checking of Bash code of this repo using ShellCheck.
Usage:
	$(basename "${0}") OPTIONS
Options:
	-h	Show this help.
	-v	Enables verbose output.
===============================================================================================================
EOH
	exit 0
}


#
# Parse commandline options
#
declare format='gcc'  # default
while getopts ":hv" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		v)
			format='tty'
			;;
		\?)
			printf '%s\n' "FATAL: Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			exit 1
			;;
		:)
			printf '%s\n' "FATAL: Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			exit 1
			;;
		*)
			printf '%s\n' "FATAL Unhandled option. Try $(basename "${0}") -h for help."
			exit 1
			;;
	esac
done

#
# Check if ShellCheck is installed.
#
which shellcheck 2>&1 >/dev/null \
	|| {
		printf '%s\n' 'FATAL: cannot find shellcheck; make sure it is installed and can be found in ${PATH}.'
		exit 1
	}

MYDIR="$(cd -P "$(dirname "${0}")" && pwd)"
#
# Run ShellCheck for all Bash scripts in the bin/ subdir.
#  * Includes sourced files, so the libraries from the lib/ subfolder 
#    are checked too as long a they are used in at least one script.
#
if [[ "${CIRCLECI}" == true ]]
then
	#
	# Exclude SC2154 (warning for variables that are referenced but not assigned),
	# because we cannot easily resolve variables sourced from etc/*.cfg config files.
	#
	export SHELLCHECK_OPTS="${SHELLCHECK_OPTS} -e SC2154"
	#
	# Reformat to add hyperlinks to the ShellCheck issues on the wiki:
	#	https://github.com/koalaman/shellcheck/wiki/SC${ISSUENUMBER}
	# explaining what is wrong with the code / style and how to improve it.
	#
	shellcheck -a -x -o all -f "${format}" "${MYDIR}"/../bin/*.sh \
		| sed "s|${MYDIR}/../||g" \
		| perl -lpe 's|\[(SC[0-9]+)\]|<a href="https://github.com/koalaman/shellcheck/wiki/$1">[$1]</a>|'
else
	shellcheck -a -x -o all -f "${format}" "${MYDIR}"/../bin/*.sh \
		| sed "s|${MYDIR}/../||g"
fi