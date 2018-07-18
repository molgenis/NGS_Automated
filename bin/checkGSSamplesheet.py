#!/usr/bin/env python

import argparse
import os
import csv     # imports the csv module
import sys
from collections import defaultdict
from os.path import basename
parser = argparse.ArgumentParser(description='Input parameters:')
parser.add_argument("--input")
parser.add_argument("--logfile")
args = parser.parse_args()

columns = defaultdict(list)
f = open(args.input, 'r') # opens the csv file
print("inputfile:" + args.input)
reader = csv.DictReader(f)  # creates the reader object
sampleName=(basename(os.path.splitext(args.input)[0]))

w = open(args.logfile, 'w')
print("logfile:" + args.logfile)
stopRun="false"
hasRows = False
listOfErrors=[]

for number, row in enumerate(reader,1):   # iterates the rows of the file in orders
        hasRows = True
	## check if the required columns are there
        for columnName in ('externalSampleID','project','sequencingStartDate','seqType','prepKit','capturingKit','barcode','barcode2','barcodeType'):
            if columnName not in row.keys():
                if stopRun == "false":
                    listOfErrors.extend("One required column is missing (or has a trailing space): " + columnName)
                    w.write("\nOne required column is missing (or has a trailing space): " + columnName)
                    stopRun="true"
                else:
                    if row[columnName] == "":
                        if columnName in ('capturingKit','barcode','barcode2','barcodeType'):
                            if stopRun == "false":
                                w.write("\nThe variable " + columnName + " on line " + str(number) +  " is empty! Please fill in None (this to be sure that is not missing)")
                                stopRun="true"
                            else:
                                if stopRun == "false":
                                    w.write("\nThe variable " + columnName + " on line " + str(number) +  " is empty!")
                                    stopRun="true"
        if stopRun == 'false':
            if row['sequencer'] != '':
                stopRun="true"
                w.write("\nFor Genomescan runs the 'sequencer' in the samplesheet must be empty.")
            if row['run'] != '':
                stopRun="true"
                w.write("\nFor Genomescan runs the 'run' in the samplesheet must be empty.")
            if row['flowcell'] != '':
                stopRun="true"
                w.write("\nFor Genomescan runs the 'flowcell' in the samplesheet must be empty.")
            if row['lane'] != '':
                stopRun="true"
                w.write("\nFor Genomescan runs the 'lane' in the samplesheet must be empty.")
if not hasRows:
    w.write("\nThe complete file is empty?!")
    listOfErrors.append("The complete file is empty?!")

if (stopRun == "true"):
	w.write("\nSamplesheet "+ sampleName + " failed.")
else:
	w.write("OK")

w.close()
f.close()      # closing