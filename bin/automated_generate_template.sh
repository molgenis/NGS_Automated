#!/bin/bash

module load NGS_DNA/VERSIONFROMSTARTPIPELINESCRIPT
module list
HOSTNAME_SHORT=$(hostname -s)
thisDir=$(pwd)

ENVIRONMENT_PARAMETERS="parameters_${HOSTNAME_SHORT}.csv"
TMPDIRECTORY=$(basename $(cd ../../ && pwd ))
GROUP=$(basename $(cd ../../../ && pwd ))

PROJECT=$1
TMP_ROOT_DIR="/groups/${GROUP}/${TMPDIRECTORY}"
RUNID=run01

## Normal user, please leave BATCH at _chr
## For expert modus: small batchsize (6) fill in '_small'  or per chromosome fill in _chr
BATCH="$2"

##Some error handling
function errorExitandCleanUp() {
    echo "${PROJECT} TRAPPED"
    if [ ! -f /groups/${GROUP}/${TMPDIRECTORY}/logs/${PROJECT}.generating.failed.mailed ]; then
        mailTo="helpdesk.gcc.groningen@gmail.com"
        tail -50 ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/generate.logger | mail -s "The generate script has crashed for run/project ${PROJECT}" ${mailTo}
        touch /groups/${GROUP}/${TMPDIRECTORY}/logs/${PROJECT}.generating.failed.mailed
    fi
}
trap "errorExitandCleanUp" HUP INT QUIT TERM EXIT ERR

samplesheet=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/${PROJECT}.csv
mac2unix $samplesheet

python ${EBROOTNGS_DNA}/samplesize.py ${samplesheet} $thisDir
SAMPLESIZE=$(cat externalSampleIDs.txt | uniq | wc -l)

python ${EBROOTNGS_DNA}/gender.py $samplesheet
var=$(cat ${samplesheet}.tmp | wc -l)

if [ $var != 0 ]; then
    mv ${samplesheet}.tmp ${samplesheet}
    echo "samplesheet updated with Gender column"
fi
echo "Samplesize is $SAMPLESIZE"

if [ $SAMPLESIZE -gt 199 ]; then
    WORKFLOW=${EBROOTNGS_DNA}/workflow_samplesize_bigger_than_200.csv
else
    WORKFLOW=${EBROOTNGS_DNA}/workflow.csv
fi

if [ -f .compute.properties ]; then
    rm .compute.properties
fi

if [ -f ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/out.csv  ]; then
    rm -rf ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/out.csv
fi

echo "tmpName,${TMPDIRECTORY}" > ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/tmpdir_parameters.csv 

perl ${EBROOTNGS_DNA}/convertParametersGitToMolgenis.pl ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/tmpdir_parameters.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/tmpdir_parameters_converted.csv

perl ${EBROOTNGS_DNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_DNA}/parameters.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/out.csv

perl ${EBROOTNGS_DNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_DNA}/parameters_${GROUP}.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/group_parameters.csv

perl ${EBROOTNGS_DNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_DNA}/${ENVIRONMENT_PARAMETERS} > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/environment_parameters.csv

sh $EBROOTMOLGENISMINCOMPUTE/molgenis_compute.sh \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/out.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/group_parameters.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/environment_parameters.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/tmpdir_parameters_converted.csv \
-p ${EBROOTNGS_DNA}/batchIDList${BATCH}.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/${PROJECT}.csv \
-w ${EBROOTNGS_DNA}/create_in-house_ngs_projects_workflow.csv \
-rundir ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/scripts \
--runid ${RUNID} \
-o "workflowpath=${WORKFLOW};\
outputdir=scripts/jobs;mainParameters=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/out.csv;\
group_parameters=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/group_parameters.csv;\
groupname=${GROUP};\
ngsversion=$(module list | grep -o -P 'NGS_DNA(.+)');\
environment_parameters=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/environment_parameters.csv;\
tmpdir_parameters=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/tmpdir_parameters_converted.csv;\
batchIDList=${EBROOTNGS_DNA}/batchIDList${BATCH}.csv;\
worksheet=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/${PROJECT}.csv" \
-weave \
--generate

trap - EXIT
exit 0
