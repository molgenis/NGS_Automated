#!/bin/bash

#
# Run ShellCheck for all Bash scripts in the bin/ subdir.
# Includes sourced files, so the libraries from the lib/ subfolder are checked too
# as long a they are used in at least one script.
#
shellcheck -a -x -f checkstyle "${WORKSPACE:-../}"/bin/*.sh | tee checkstyle-result.xml
#
# Reformat the generated report to add hyperlinks to the ShellCheck issues on the wiki:
#	https://github.com/koalaman/shellcheck/wiki/SC${ISSUENUMBER}
# explaining whatis wrong with the code / style and how to improve it.
#
perl -pi -e "s|message='([^']+)'\s+source='ShellCheck.(SC[0-9]+)'|message='&lt;a href=&quot;https://github.com/koalaman/shellcheck/wiki/\$2&quot;&gt;\$2: \$1&lt;/a&gt;' source='ShellCheck.\$2'|" checkstyle-result.xml
