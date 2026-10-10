#!/bin/bash
# r3-call-lib.sh <bin-dir> <function> <args...>: source the classify library (which loads the status readers) and call one function.
bindir=$1; shift
. "$bindir/fm-classify-lib.sh"
"$@"
