#!/bin/bash

FIND="$1"
REPLACE="$2"
OUTDIR="$3"
ACTION="$4"

echo $FIND - $REPLACE

# todo: parse args, validate them, print usage etc

for f in *; do
    echo $f
    n=`echo $f | sed "s/$FIND/$REPLACE/g"`

    DEST="$OUTDIR/$n"
    if [ "$ACTION" == "cp" ]; then
        echo "Copying to $DEST"
        cp "$f" "$DEST"
    elif [ "$ACTION" == "mv" ]; then
        echo "Moving to $DEST"
        mv "$f" "$DEST"
    else
        echo "$n"
    fi

    echo "===="

done

