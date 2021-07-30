#!/bin/bash

RAPIDS_MG_TOOLS_DIR=${RAPIDS_MG_TOOLS_DIR:=$(cd $(dirname $0); pwd)}
source ${RAPIDS_MG_TOOLS_DIR}/script-env.sh

ALL_REPORTS=$(ls ${RESULTS_DIR}/pytest-results-*.txt 2> /dev/null)

################################################################################
# create the html reports for each individual run (each
# pytest-results*.txt file)
if [ "$ALL_REPORTS" != "" ]; then
    for report in $ALL_REPORTS; do
        report_name=$(basename -s .txt $report)
        html=${RESULTS_DIR}/${report_name}.html
        echo "<!doctype html>
<html>
<head>
   <title>${report_name}</title>
</head>
<body>
<h1>${report_name}</h1><br>
<table style=\"width:100%\">
   <tr>
      <th>test file</th><th>status</th><th>logs</th>
   </tr>
" > $html
        awk '{ if($2 == "FAILED") {
                  color = "red"
              } else {
                  color = "green"
              }
              printf "<tr><td>%s</td><td style=\"color:%s\">%s</td><td><a href=%s/index.html>%s</a></td></tr>\n", $1, color, $2, $3, $3
             }' $report >> $html
        echo "</table>
    </body>
    </html>
    " >> $html
    done
fi

################################################################################
# create the top-level report
STATUS='FAILED'
STATUS_IMG='https://img.icons8.com/cotton/80/000000/cancel--v1.png'
if [ "$ALL_REPORTS" != "" ]; then
    if ! (grep -w FAILED $ALL_REPORTS > /dev/null); then
        STATUS='PASSED'
        STATUS_IMG='https://img.icons8.com/bubbles/100/000000/approval.png'
    fi
fi
BUILD_LOG_HTML="(build log not available or build not run)"
BUILD_STATUS=""
if [ -f $BUILD_LOG_FILE ]; then
    BUILD_LOG_HTML="<a href=$(basename $BUILD_LOG_FILE)>log</a>"
    if (tail -1 $BUILD_LOG_FILE | grep -qw "done."); then
        BUILD_STATUS="PASSED"
    else
        BUILD_STATUS="FAILED"
    fi
fi

report=${RESULTS_DIR}/report.html
echo "<!doctype html>
<html>
<head>
   <title>test report</title>
</head>
<body>
" > $report
echo "<img src=\"${STATUS_IMG}\" alt=\"${STATUS}\"/> Overall status: $STATUS<br>" >> $report
echo "Build: ${BUILD_STATUS} ${BUILD_LOG_HTML}<br>" >> $report
if [ "$ALL_REPORTS" != "" ]; then
    echo "   <table style=\"width:100%\">
   <tr>
      <th>run</th><th>status</th>
   </tr>
   " >> $report
    for f in $ALL_REPORTS; do
        report_name=$(basename -s .txt $f)
        if (grep -w FAILED $f > /dev/null); then
            status="FAILED"
            color="red"
        else
            status="PASSED"
            color="green"
        fi
        echo "<tr><td><a href=${report_name}.html>${report_name}</a></td><td style=\"color:${color}\">${status}</td></tr>" >> $report
    done
    echo "</table>" >> $report
else
    echo "Tests were not run." >> $report
fi
echo "</body>
</html>
" >> $report

################################################################################
# Create an index.html for each dir (ALL_DIRS plus ".")
# This is needed since S3 (and probably others) will not show the
# contents of a hosted directory by default, but will instead return
# the index.html if present.
# The index.html will just contain links to the individual files and
# subdirs present in each dir, just as if browsing in a file explorer.
ALL_DIRS=$(find -L $RESULTS_DIR -type d -printf "%P\n")

for d in "." $ALL_DIRS; do
    index=${RESULTS_DIR}/${d}/index.html
    echo "<!doctype html>
<html>
<head>
   <title>$d</title>
</head>
<body>
<h1>${d}</h1><br>
" > $index
    for f in $(ls ${RESULTS_DIR}/$d); do
        b=$(basename $f)
        if [[ "$b" == "index.html" ]]; then
            continue
        fi
        if [ -d "${RESULTS_DIR}/${d}/${f}" ]; then
            echo "<a href=$b/index.html>$b</a><br>" >> $index
        else
            echo "<a href=$b>$b</a><br>" >> $index
        fi
    done
    echo "</body>
</html>
" >> $index
done