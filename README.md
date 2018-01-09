# NGS_Automated

Automation using Bash scripts and Cron jobs for Molgenis Compute pipelines from:
 - NGS_DNA
 - NGS_RNA

#### Code style

- Indentation: <TABS>
- environment variables: ALL\_UPPERCASE\_WITH\_UNDERSCORES
- global script variables: camelCase
- local function variables: _camelCasePrefixedWithUnderscore
- `if ... then`, `while ... do` and `for ... do` not on a single line, but on two lines with the `then` or `do` on the next line. E.g.
  ```
  if ...
  then
      ...
  elif ...
  then
      ...
  fi
  ```


## Version 1.x
See separate README_v1.md for details on the (deprecated) version
## Version 2.x

#### Repo layout
```

|-- bin/......................... Bash scripts for managing data staging, data analysis and monitoring / error handling.
|-- etc/......................... Config files in bash syntax. Config files are sourced by the scripts in bin/.
|   |-- <group>.cfg.............. Group specific variables.
|   |-- <site>.cfg............... Site / server specific variables.
|   `-- sharedConfig.cfg......... Generic variables, which are the same for all group and all sites / servers.
`-- lib/
    `-- sharedFunctions.bash..... Generic functions for error handling, logging, track & trace, etc.
```

#### Data flow

```
   ⎛¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯⎞
   ⎜ LFS  ⎜ Dedicated pre processing server to create FastQ files                        ⎜
   ⎜ scr* ⎜ multiplexed rawer data (BCL format) -> demultiplexed raw data (FastQ format) ⎜
   ⎝______________________________________________________________________________________⎠
      v
      v
      1: copyRawDataToPrm
      v
      v
   ⎛¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯⎞
   ⎜ LFS  ⎜ HPC cluster                                                         ⎜ LFS  ⎜>>> 4: notifications
   ⎜ prm* ⎜ demultiplexed raw data (FastQ format) -> variant calls (VCF format) ⎜ tmp* ⎜>>> 5: cleanup
   ⎝____________________________________________________________________________________⎠
      ^ v                                                                           ^ v
      ^ `>>>>>>>>>>>>>>>>>>>>>>>>> 2: startPipeline >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>^ v
      ^                                                                               v
       `<<<<<<<<<<<<<<<<<<<<<<<<<< 3: copyProjectDataToPrm <<<<<<<<<<<<<<<<<<<<<<<<<<<
```

#### Job control flow

The path to phase.state files must be:
```
${TMP_ROOT_DIR}/logs/${project}/${run}.${phase}.${state}
```
Phase is in most cases the name of the executing script as determined by ```${SCRIPT_NAME}```.
State is either ```started```, ```failed``` or ```finished```.

 * For 'sequence projects':
    * ${project} = the 'run' as determined by the sequencer.
    * ${run}     = the 'run' as determined by the sequencer.
   Hence ${project} = {run} = [SequencingStartDate]_[Sequencer]_[RunNumber]_[Flowcell]
 * For 'analysis projects':
    * ${project} = the 'project' name as specified in the sample sheet.
	* ${run}     = the incremental 'analysis run number'. Starts with run01 and incremented in case of re-analysis.

```
(NGS_Demultiplexing) automate.sh => ${sourceServer}:${SCR_ROOT_DIR}/logs/${run}_Demultiplexing.

## RUNNING ##

touch ${sourceServer}:${SCR_ROOT_DIR}/logs/${run}_Demultiplexing.finished
	||
	\/
CopyRawDataToPrm.sh -g GROUP -s GATTACA => ${cluster}:${TMP_ROOT_DIR}/logs/copyRawDataToPrm.lock
                                           ${cluster}:${TMP_ROOT_DIR}/logs/${run}/${run}.copyRawDataToPrm.started
                                           ${cluster}:${TMP_ROOT_DIR}/logs/${run}/${run}.copyRawDataToPrm.failed
                                           ${cluster}:${TMP_ROOT_DIR}/logs/${run}/${run}.copyRawDataToPrm.failed.mailed
                                           ${cluster}:${TMP_ROOT_DIR}/logs/${run}/${run}.copyRawDataToPrm.finished
                                           ${cluster}:${TMP_ROOT_DIR}/logs/${run}/${run}.copyRawDataToPrm.finished.mailed

                                           ${cluster}:${TMP_ROOT_DIR}/logs/${_run}.samplesheetSplittedPerProject"

## COPYING ##

Check which sample sheets feed into startPipeline! ${cluster}:${TMP_ROOT_DIR}/Samplesheets/project_${cluster}/${project}.csv
	||
	\/
startPipeline.sh -g GROUP => ${project}.scriptsGenerated # Refactor to use *.${phase}.${state} syntax
                             ${cluster}:${TMP_ROOT_DIR}/logs/${project}/${run}.pipeline.started 

## RUNNING ##

${cluster}:${TMP_ROOT_DIR}/logs/${project}/${run}.pipeline.finished
	||
	\/
copyProjectDataToPrm.sh -g GROUP => ${cluster}:${TMP_ROOT_DIR}/logs/copyProjectDataToPrm.lock
                                    ${cluster}:${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrm.started
                                    ${cluster}:${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrm.failed
                                    ${cluster}:${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrm.finished

## COPYING ##

${cluster}:${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataToPrm.finished

```

#### notifications.sh

To configure e-mail notification by the notifications script, 
edit the ```NOTIFY_FOR_PHASE_WITH_STATE``` array in ```etc/${group}.cfg``` 
and list the <phase>:<state> combinations for which email should be sent. E.g.:
```
declare -a NOTIFY_FOR_PHASE_WITH_STATE=(
	'copyRawDataToPrm:failed'
	'copyRawDataToPrm:finished'
	'pipeline:failed'
	'copyProjectDataToPrm:failed'
	'copyProjectDataToPrm:finished'
)
```
In addition there must be a list of e-mail addresses (one address per line) for each state for which email notifications are enabled in:
```
${TMP_ROOT_DIR}/logs/${phase}.mailinglist
```
In case the list of addresses is the same for mutiple states, you can use symlinks per state. E.g.
```
${TMP_ROOT_DIR}/logs/all.mailinglist
${TMP_ROOT_DIR}/logs/${phase1}.mailinglist -> ./all.mailinglist
${TMP_ROOT_DIR}/logs/${phase2}.mailinglist -> ./all.mailinglist
```

#### cleanup.sh

The cleanup script runs once a day, it will clean up old data:
- Remove all the GavinStandAlone project/generatedscripts/tmp data once the GavinStandAlone has a ${project}.vcf.finished in ${TMP_ROOT_DIR}/GavinStandAlone/input
- Clean up all the raw data that is older than 30 days, it first checks if the data is copied to prm 
  - check in the logs if ${filePrefix}.copyRawDataToPrm.sh.finished 
  - count *.fq.gz on tmp and prm and compare for an extra check
- All the project + tmp data older than 30 days will also be deleted
  - when ${project}.projectDataCopiedToPrm.sh.finished

#### Who runs what and where

|Script                  |User              |Running on site/server     |
|------------------------|------------------|---------------------------|
|1. copyRawDataToPrm     |${group}-dm       |HPC Cluster with prm mount |
|2. startPipeline        |${group}-ateambot |HPC Cluster with tmp mount |
|3. copyProjectDataToPrm |${group}-dm       |HPC Cluster with tmp mount |
|4. notifications        |${group}-ateambot |HPC Cluster with tmp mount |
|5. cleanup              |${group}-ateambot |HPC Cluster with tmp mount |


#### Location of job control and log files

 - LFS = logical file system; one of arc*, scr*, tmp* or prm*.
 - NGS_DNA and NGS_RNA pipelines produce data per project in a run sub dir for each (re)analysis of the data.
   These pipelines do not generate data outside the projects folder.
 - NGS_Automated has it's own dirs and does NOT touch/modify/create any data in the projects dir.

```
/groups/${group}/${LFS}/
                 |-- Samplesheets/
                 |   |-- archive
                 |   |-- new?
                 |-- generatedscripts/
                 |-- logs/............................ Logs from NGS_Automated.
                 |   |-- ${SCRIPT_NAME}.mailinglist... List of email addresses used by the notifications script 
                 |   |                                 to report on state [failed|finished] of script ${SCRIPT_NAME}.
                 |   |                                 Use one email address per line or space separated addresses.
                 |   |-- ${SCRIPT_NAME}.lock           Locking file to prevent multiple copies running simultaneously.
                 |   `-- ${project}/
                 |       |-- ${run}.${SCRIPT_NAME}.log
                 |       |-- ${run}.${SCRIPT_NAME}.[started|failed|finished]
                 |       |-- ${run}.${SCRIPT_NAME}.[started|failed|finished].mailed
                 |-- projects/
                 |   |-- ${run}.md5....... MD5 checksums for all files of the corresponding ${run} dir.
                 |   `-- ${run}/
                 |       |-- jobs/........ Generated Bash scripts for this pipeline/analysis run.
                 |       |-- logs/........ Only logs for this pipeline/analysis run, so no logs from NGS_Automated.
                 |       |-- qc/.......... Quality Control files.
                 |       |-- rawdata/..... Relative symlinks to the rawdata and corresponding checksums.
                 |       |   |-- array/... Symlinks point to actual data in ../../../../../rawdata/array/
                 |       |   `-- ngs/..... Symlinks point to actual data in ../../../../../rawdata/ngs/
                 |       `-- results/..... Result files for this pipeline/analysis run.
                 `-- rawdata/
                     |-- array/
                     `-- ngs/
```

