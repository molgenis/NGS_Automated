# NGS_Automated

Automation using Bash scripts and Cron jobs for Molgenis Compute pipelines from:
 - NGS_DNA
 - NGS_RNA
 
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

## 1. Data flow 1.x
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

## 2. Data flow 2.x

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
 v    ^                                  |_automated_DNA_generate_template.sh         v
 v    ^                                  |_automated_RNA_generate_template.sh         v
 v    ^                                                                               v
 v     `<<<<<<<<<<<<<<<<<<<<<<<<<< 3: copyProjectDataToPrm <<<<<<<<<<<<<<<<<<<<<<<<<<<
 v
 `>>> 4: monitorProjects (previously pipelineFinished + mailError)
```