import argparse
import csv     # imports the csv module
import sys
from collections import defaultdict

parser = argparse.ArgumentParser(description='Process some integers.')
parser.add_argument("--input")
parser.add_argument("--logfile")
args = parser.parse_args()

columns = defaultdict(list)
f = open(args.input, 'r') # opens the csv file
print("inputfile:" + args.input)
reader = csv.DictReader(f)  # creates the reader object

w = open(args.logfile, 'w')
print("logfile:" + args.logfile)

alreadyErrored="false"
hasRows = False
for number, row in enumerate(reader,1):   # iterates the rows of the file in orders
        hasRows = True
        for sleutel in ('externalSampleID','project','sequencer','sequencingStartDate','flowcell','run','flowcell','lane','seqType','prepKit','capturingKit','barcode','barcodeType'):
                if sleutel not in row.keys():
                        if alreadyErrored == "false":

                                w.write("One of the headers is missing: (externalSampleID,project,sequencer,sequencingStartDate,flowcell,run,flowcell,lane,seqType,prepKit,capturingKit,barcode,barcodeType)")
                                print("One of the headers is missing: (externalSampleID,project,sequencer,sequencingStartDate,flowcell,run,flowcell,lane,seqType,prepKit,capturingKit,barcode,barcodeType) in " + args.input)
                                alreadyErrored="true"
                else:
                     	if row[sleutel] == "":
                                if sleutel in ('capturingKit','barcode','barcodeType'):
                                        if alreadyErrored == "false":
                                                w.write("The variable " + sleutel + " on line " + str(number) +  " is empty! Please fill in None (this to be sure that is not missing)")
                                                print("The variable " + sleutel + " on line " + str(number) +  " is empty! Please fill in None (this to be sure that is not missing) in "+ args.input)
                                                alreadyErrored="true"
                                else:
                                     	if alreadyErrored == "false":
                                                print("The variable " + sleutel + " on line " + str(number) +  " is empty! in "+ args.input)
                                                w.write("The variable " + sleutel + " on line " + str(number) +  " is empty!")
                                                alreadyErrored="true"

if not hasRows:
        print("The complete file is empty?! in "+ args.input)
        w.write("The complete file is empty?!")

w.close()
f.close()      # closing
