#
##get the date of today, so the reports are in a directory per date
#
TODAY=$(date '+%Y%m%d')

#
## ngs-pipeline reports
#
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p seqOverview -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" Exoom "${CHRONQC_TEMPLATE_DIRS}/chronqc.seqOverview.json"
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p seqOverview -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" Targeted "${CHRONQC_TEMPLATE_DIRS}/chronqc.seqOverview.json"

#
## Array and Lab  reports
#
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" NGSlab "${CHRONQC_TEMPLATE_DIRS}/chronqc.NGSlab.json"
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p Concentratie -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" Nimbus "${CHRONQC_TEMPLATE_DIRS}/chronqc.Concentratie.json"

chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p ArrayInzetten -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" labpassed "${CHRONQC_TEMPLATE_DIRS}/chronqc.ArrayInzetten_labpassed.json"
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p ArrayInzetten -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" all "${CHRONQC_TEMPLATE_DIRS}/chronqc.ArrayInzetten_all.json"


#
## Sequence run report, when we have enhough data points to generate boxplots, the chronqc.SequenceRun.json can be used, until then chronqc.SequenceRunNoBoxplots.json will be used.  
#
#chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p SequenceRun -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" NB501043 "${CHRONQC_TEMPLATE_DIRS}/chronqc.SequenceRunNoBoxplots.json"
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p SequenceRun -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" NB501043 "${CHRONQC_TEMPLATE_DIRS}/chronqc.SequenceRun.json"
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p SequenceRun -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" NB501093 "${CHRONQC_TEMPLATE_DIRS}/chronqc.SequenceRun.json"
chronqc plot -o "${CHRONQC_REPORTS_DIRS}/${TODAY}/" -p SequenceRun -f "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" NB552735 "${CHRONQC_TEMPLATE_DIRS}/chronqc.SequenceRun.json"




