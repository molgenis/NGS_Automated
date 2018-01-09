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


## Version 1.x (Outdated)

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
