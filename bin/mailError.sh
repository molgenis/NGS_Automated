#!/bin/bash

set -e
set -u

groupname=$1
MYINSTALLATIONDIR=$( cd -P "$( dirname "$0" )" && pwd )

#
# Source config files.
#
HOSTNAME_SHORT=$(hostname -s)
. ${MYINSTALLATIONDIR}/${groupname}.cfg
. ${MYINSTALLATIONDIR}/${HOSTNAME_SHORT}.cfg
. ${MYINSTALLATIONDIR}/sharedConfig.cfg

ALLFINISHED=()
if ls ${TMP_ROOT_DIR}/logs/*.pipeline.failed 1> /dev/null 2>&1 
then
	ls ${TMP_ROOT_DIR}/logs/*.pipeline.failed > ${TMP_ROOT_DIR}/logs/pipeline.failed.csv
else
	exit 0
fi

while read line 
do
	ALLFAILED+=("${line} ")
done<${TMP_ROOT_DIR}/logs/pipeline.failed.csv

for i in ${ALLFAILED[@]}
do
	filename=$(basename $i)
	projectName="${filename%%.*}"
	
	mailTo="helpdesk.gcc.groningen@gmail.com"
        if [ $groupname == "umcg-gaf" ]
        then
                mailTo="helpdesk.gcc.groningen@gmail.com"
        elif [ "${groupname}" == "umcg-gd" ]
        then
                if [ -f /groups/umcg-gd/${TMP_FS}/logs/mailinglistDiagnostiekCrash.txt ]
                then
                       	mailTo=$(cat /groups/umcg-gd/${TMP_FS}/logs/mailinglistDiagnostiekCrash.txt)
                else
                      	echo "mailingListDiagnostiekCrash.txt bestaat niet!!"
                        exit 0
                fi
        fi
	
	if [ ! -f ${TMP_ROOT_DIR}/logs/${projectName}.pipeline.failed.mailed ]
	then
		HEADER=$(head -1 ${TMP_ROOT_DIR}/logs/${projectName}.pipeline.failed)
		echo "mailed error to ${mailTo}"
		cat ${TMP_ROOT_DIR}/logs/${projectName}.pipeline.failed | mail -s "The NGS_DNA pipeline on ${HOSTNAME_SHORT} has crashed for project ${projectName} on step ${HEADER}" ${mailTo}
		touch ${TMP_ROOT_DIR}/logs/${projectName}.pipeline.failed.mailed
	fi
done
