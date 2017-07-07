#!/bin/bash

module load NGS_RNA/VERSIONFROMSTARTPIPELINESCRIPT
module list

HOSTNAME_SHORT=$(hostname -s)
##Running script for checking the environment variables

ENVIRONMENT="${HOST%%.*}"
TMPDIR=$(basename $(cd ../../ && pwd ))
GROUP=$(basename $(cd ../../../ && pwd ))

PROJECT=$1
RUNID="run01"

TMP_ROOT_DIR="/groups/${GROUP}/${TMPDIR}"
BUILD=$2
SPECIES=$3
PIPELINE=$4

WORKFLOW=${EBROOTNGS_RNA}/workflow_${PIPELINE}.csv

if [ -f .compute.properties ];
then
     rm .compute.properties
fi

if [ -f ${GAF}/generatedscripts/${PROJECT}/out.csv  ];
then
	rm -rf ${GAF}/generatedscripts/${PROJECT}/out.csv
fi

perl ${EBROOTNGS_RNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_RNA}/parameters.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.csv

perl ${EBROOTNGS_RNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_RNA}/parameters.${BUILD}.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${BUILD}.csv

perl ${EBROOTNGS_RNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_RNA}/parameters.${SPECIES}.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${SPECIES}.csv

perl ${EBROOTNGS_RNA}/convertParametersGitToMolgenis.pl ${EBROOTNGS_RNA}/parameters.${HOSTNAME_SHORT}.csv > \
${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${HOSTNAME_SHORT}.csv

sh ${EBROOTMOLGENISMINCOMPUTE}/molgenis_compute.sh \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${BUILD}.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${SPECIES}.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${HOSTNAME_SHORT}.csv \
-p ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/${PROJECT}.csv \
-p ${EBROOTNGS_RNA}/chromosomes.${SPECIES}.csv \
-w ${EBROOTNGS_RNA}/create_in-house_ngs_projects_workflow.csv \
-rundir ${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/scripts \
--runid ${RUNID} \
--weave \
--generate \
-o "workflowpath=${WORKFLOW};outputdir=scripts/jobs;\
groupname=${GROUP};\
mainParameters=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.csv;\
ngsversion=$(module list | grep -o -P 'NGS_RNA(.+)');\
worksheet=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/${PROJECT}.csv;\
parameters_build=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${BUILD}.csv;\
parameters_species=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${SPECIES}.csv;\
parameters_chromosomes=${EBROOTNGS_RNA}/chromosomes.${SPECIES}.csv;\
parameters_environment=${TMP_ROOT_DIR}/generatedscripts/${PROJECT}/parameters.${HOSTNAME_SHORT}.csv;"
