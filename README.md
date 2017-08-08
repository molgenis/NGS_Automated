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

#### Data flow

```
   ⎛¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯⎞
   ⎜ LFS  ⎜ Dedicated pre processing server to create FastQ files                        ⎜
   ⎜ scr* ⎜ multiplexed rawer data (BCL format) -> demultiplexed raw data (FastQ format) ⎜
   ⎝______________________________________________________________________________________⎠
      v v                                                                           
      v `>>>>>>>>>>>>>>>>>>>>>>>>> 1: copyRawDataTo*Cluster >>>>>>>>>>>>>>>>>>>>>>>>>
      v                                                                              v
      2: copyRawDataToPrm                                                            v
      v                                                                              v
      v                                                                              v
   ⎛¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯⎞>>>>>
   ⎜ LFS  ⎜ HPC cluster                                                         ⎜ LFS  ⎜    v
   ⎜ prm* ⎜ demultiplexed raw data (FastQ format) -> variant calls (VCF format) ⎜ tmp* ⎜    3: startPipeline
   ⎜      ⎜                                                                     ⎜      ⎜    v       |_automated_generate_template.sh
   ⎝____________________________________________________________________________________⎠<<<<<       |_automated_RNA_generate_template.sh
        ^                                                                           v v
        ^                                                                           v v
        `<<<<<<<<<<<<<<<<<<<<<<<<< 5: copyProjectDataToPrm <<<<<<<<<<<<<<<<<<<<<<<<<  v
                                                                                      v
                                                                                      4: pipelineFinished
                                                                                         mailError
```

#### Location of job control and log files

?

## Version 2.x

#### Repo layout
```

|-- bin/......................... Bash scripts for managing data staging, data analysis and monitoring / error handling.
|-- etc/......................... Config files in bash syntax. Config files are sourced by the scripts in bin/.
|   |-- <group>.cfg.............. Group specific variables.
|   |-- <site>.cfg............... Site / server specific variables.
|   `-- sharedConfig.cfg......... Generic variables, which are the same for all group and all sites / servers.
`-- lib/
    `-- sharedFunctions.bash..... Generic functions for error handling, logging, etc.
```

#### Data flow

Changes:
 - Make _copyRawDataToPrm_ the first step
 - Refactor _copyRawDataToCluster_ to fetch raw data from _prm_ on cluster as opposed to from _scr_ on dedicated preprocessing server.
  - Refactor to stage data from _prm_ to _tmp_ as part of the first step of a pipeline as opposed to in separate cron job.
  - Make data staging job run in QoS _ds_
 - Merge _pipelineFinished_ and _mailError_ into a single notifaction/monitoring script
  - that runs after _copyProjectDataToPrm_ and
  - monitors _prm_ as opposed to _tmp_.

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
   ⎜ LFS  ⎜ HPC cluster                                                         ⎜ LFS  ⎜
  <⎜ prm* ⎜ demultiplexed raw data (FastQ format) -> variant calls (VCF format) ⎜ tmp* ⎜
 v ⎝____________________________________________________________________________________⎠
 v    ^ v                                                                           ^ v
 v    ^ `>>>>>>>>>>>>>>>>>>>>>>>>> 2: startPipeline >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>^ v
 v    ^                                                                               v
 v     `<<<<<<<<<<<<<<<<<<<<<<<<<< 3: copyProjectDataToPrm <<<<<<<<<<<<<<<<<<<<<<<<<<<
 v
 `>>> 4: notifications
```

|Script                  |User              |Running on site/server|
|------------------------|------------------|----------------------|
|1. copyRawDataToPrm     |${group}-dm       |HPC Cluster           |
|2. startPipeline        |${group}-ateambot |HPC Cluster           |
|3. copyProjectDataToPrm |${group}-dm       |HPC Cluster           |
|4. notifications        |${group}-ateambot |HPC Cluster           |


#### Location of job control and log files

 - LFS = logical file system; one of arc*, scr*, tmp* or prm*.
 - NGS_DNA and NGS_RNA pipelines produce data per project in a run sub dir for each (re)analysis of the data.
   These pipelines do not generate data outside the projects folder.
 - NGS_Autmotated has it's own dirs and does NOT touch/modify/create any data in the projects dir.

```
/groups/${group}/${LFS}/
                 |-- generatedscripts/
                 |-- logs/............................ Logs from NGS_Automated.
                 |   |-- ${SCRIPT_NAME}.mailinglist... List of email addresses used by the notifications script 
                 |   |                                 to report on state [failed|finished] of script ${SCRIPT_NAME}.
                 |   |                                 Use one email address per line or space separated addresses.
                 |   `-- ${project}/
                 |       |-- ${run}.${SCRIPT_NAME}.log
                 |       |-- ${run}.${SCRIPT_NAME}.[failed|finished]
                 |       |-- ${run}.${SCRIPT_NAME}.[failed|finished].mailed
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
```

