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
if ls ${TMP_ROOT_DIR}/logs/*.pipeline.finished 1> /dev/null 2>&1 
then
	ls ${TMP_ROOT_DIR}/logs/*.pipeline.finished > ${TMP_ROOT_DIR}/logs/AllProjects.pipeline.finished.csv
else
	exit 0
fi
while read line 
do
	ALLFINISHED+=("${line} ")
done<${TMP_ROOT_DIR}/logs/AllProjects.pipeline.finished.csv


for i in ${ALLFINISHED[@]}
do
	filename=$(basename $i)
	projectName="${filename%%.*}"

	## Check which rawdata belongs to the project
	for i in $(ls ${TMP_ROOT_DIR}/projects/${projectName}/*/rawdata/ngs/*.md5)
 	do 
		if [ -L $i ]
		then 
			readlink $i > ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalink 
		fi
	done
	## if md5sums for are not present try to fix it via the fq.gz
	if [ ! -f  ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalink ]
        then
                for i in $(ls ${TMP_ROOT_DIR}/projects/${projectName}/*/rawdata/ngs/*.fq.gz)
                do
                        if [ -L $i ]
                        then
                                readlink $i > ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalink

                        fi
                done
        fi

	rawdataName=""
        if [  -f  ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalink ]
        then
		while read line 
		do 
			dirname $line > ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalinkDirName 
		done<${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalink

		rawDataName=$(while read line ; do basename $line ; done<${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalinkDirName)
	fi

	echo "moving ${projectName} files to ${TMP_ROOT_DIR}/logs/${projectName}/ and removing tmp finished files"
	if [[ -f ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.pipeline.logger  && -f ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.pipeline.started ]]
	then 
		if [[ -f ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalink && -f ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.rawdatalinkDirName ]]
		then
			touch ${TMP_ROOT_DIR}/logs/${projectName}/${rawDataName}
		fi
	

	else
		echo "there is/are missing some files:${projectName}.pipeline.logger or  ${projectName}.pipeline.started"
		echo "there is/are missing some files:${projectName}.pipeline.logger or  ${projectName}.pipeline.started" >> ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.pipeline.logger
	fi
	if [ ! -f ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.pipeline.finished.mailed ]
        then
            	mailTo="helpdesk.gcc.groningen@gmail.com"
                if [ $groupname == "umcg-gaf" ]
                then
                    	mailTo="helpdesk.gcc.groningen@gmail.com"
                elif [ "${groupname}" == "umcg-gd" ]
                then
                    	if [ -f /groups/umcg-gd/${TMP_FS}/logs/mailinglistDiagnostiek.txt ]
                        then
                            	mailTo=$(cat /groups/umcg-gd/${TMP_FS}/logs/mailinglistDiagnostiek.txt)
                        else
                            	echo "mailingListDiagnostiek.txt bestaat niet!!"
                                exit 0
                        fi
                fi
		#cd ${TMP_ROOT_DIR}/projects/${projectName}/*/jobs/
	
		#zip -gr ${TMP_ROOT_DIR}/logs/${projectName}/allJobs.zip *.err
		#zip -gr ${TMP_ROOT_DIR}/logs/${projectName}/allJobs.zip *.out
		#zip -gr ${TMP_ROOT_DIR}/logs/${projectName}/allJobs.zip *.sh.finished
		#zip -gr ${TMP_ROOT_DIR}/logs/${projectName}/allJobs.zip *.env
		#zip -gr ${TMP_ROOT_DIR}/logs/${projectName}/allJobs.zip *.sh
		#zip -gr ${TMP_ROOT_DIR}/logs/${projectName}/allJobs.zip molgenis.*
		
		#echo "all files in the jobs directory are now zipped into one file"

		#rm ${TMP_ROOT_DIR}/projects/${projectName}/*/jobs/*{err,out,sh.finished,env,sh,CORRECT}
                printf "The results can be found: ${TMP_ROOT_DIR}/projects/${projectName} \n\nCheers from the GCC :)"| mail -s "NGS_DNA pipeline is finished for project ${projectName} on `date +%d/%m/%Y` `date +%H:%M`" ${mailTo}
		mv ${TMP_ROOT_DIR}/logs/${projectName}.pipeline.finished ${TMP_ROOT_DIR}/logs/${projectName}/
                touch ${TMP_ROOT_DIR}/logs/${projectName}/${projectName}.pipeline.finished.mailed

        fi

done

