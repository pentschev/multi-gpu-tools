#!/bin/bash
# Copyright (c) 2021, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

RAPIDS_MG_TOOLS_DIR=${RAPIDS_MG_TOOLS_DIR:-$(cd $(dirname $0); pwd)}
source ${RAPIDS_MG_TOOLS_DIR}/script-env.sh

# Logs can be written to a specific location by setting the LOGS_DIR
# env var. If unset, all logs are created under a dir named after the
# current PID.
LOGS_DIR=${LOGS_DIR:-${RESULTS_DIR}/dask_logs-$$}

########################################
NUMARGS=$#
ARGS=$*
function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}
VALIDARGS="-h --help scheduler workers"
HELP="$0 [<app> ...] [<flag> ...]
 where <app> is:
   scheduler        - start dask scheduler
   workers          - start dask workers
 and <flag> is:
   -h | --help      - print this text

 WORKSPACE dir is: $WORKSPACE
"

START_SCHEDULER=0
START_WORKERS=0

if (( ${NUMARGS} == 0 )); then
    echo "${HELP}"
    exit 0
else
    if hasArg -h || hasArg --help; then
        echo "${HELP}"
        exit 0
    fi
    for a in ${ARGS}; do
        if ! (echo " ${VALIDARGS} " | grep -q " ${a} "); then
            echo "Invalid option: ${a}"
            exit 1
        fi
    done
fi

if hasArg scheduler; then
    START_SCHEDULER=1
fi
if hasArg workers; then
    START_WORKERS=1
fi

########################################

export DASK_UCX__CUDA_COPY=True
export DASK_UCX__TCP=True
export DASK_UCX__NVLINK=True
export DASK_UCX__INFINIBAND=True  ###
export DASK_UCX__RDMACM=True   ###
export DASK_RMM__POOL_SIZE=0.5GB
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT="100s"
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP="600s"
export DASK_DISTRIBUTED__COMM__RETRY__DELAY__MIN="1s"
export DASK_DISTRIBUTED__COMM__RETRY__DELAY__MAX="60s"
export DASK_DISTRIBUTED__WORKER__MEMORY__Terminate="False"

#export DASK_UCX__REUSE_ENDPOINTS=False   ###
export UCXPY_IFNAME="ib0"   ###
#export UCX_NET_DEVICES=all   ###
export UCX_MAX_RNDV_RAILS=1  # <-- must be set in the client env too!
#export DASK_UCX_SOCKADDR_TLS_PRIORITY=sockcm   ###
#export DASK_UCX_TLS=rc,sockcm,cuda_ipc,cuda_copy   ###
export DASK_LOGGING__DISTRIBUTED="DEBUG"

ulimit -n 100000
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7

SCHEDULER_ARGS="--protocol=ucx
                --port=8792
                --interface=ib0
                --scheduler-file $SCHEDULER_FILE
               "

WORKER_ARGS="--enable-tcp-over-ucx
             --enable-nvlink 
             --enable-infiniband
             --enable-rdmacm
             --rmm-pool-size=$WORKER_RMM_POOL_SIZE
             --local-directory=/tmp/$LOGNAME 
             --scheduler-file=$SCHEDULER_FILE
            "
#             --net-devices=ib0

SCHEDULER_LOG=${LOGS_DIR}/scheduler_log.txt
WORKERS_LOG=${LOGS_DIR}/worker-${HOSTNAME}_log.txt

########################################

scheduler_pid=""
worker_pid=""
num_scheduler_tries=0

function startScheduler {
    mkdir -p $(dirname $SCHEDULER_FILE)
    echo "RUNNING: \"python -m distributed.cli.dask_scheduler $SCHEDULER_ARGS\"" > $SCHEDULER_LOG
    python -m distributed.cli.dask_scheduler $SCHEDULER_ARGS >> $SCHEDULER_LOG 2>&1 &
    scheduler_pid=$!
}

mkdir -p $LOGS_DIR
logger "Logs written to: $LOGS_DIR"

if [[ $START_SCHEDULER == 1 ]]; then
    rm -f $SCHEDULER_FILE $SCHEDULER_LOG $WORKERS_LOG

    startScheduler
    sleep 6
    num_scheduler_tries=$(echo $num_scheduler_tries+1 | bc)
    
    # Wait for the scheduler to start first before proceeding, since
    # it may require several retries (if prior run left ports open
    # that need time to close, etc.)
    while [ ! -f "$SCHEDULER_FILE" ]; do
        scheduler_alive=$(ps -p $scheduler_pid > /dev/null ; echo $?)
        if [[ $scheduler_alive != 0 ]]; then
            if [[ $num_scheduler_tries != 30 ]]; then
                echo "scheduler failed to start, retry #$num_scheduler_tries"
                startScheduler
                sleep 6
                num_scheduler_tries=$(echo $num_scheduler_tries+1 | bc)
            else
                echo "could not start scheduler, exiting."
                exit 1
            fi
        fi
    done
    echo "scheduler started."
fi

if [[ $START_WORKERS == 1 ]]; then
    rm -f $WORKERS_LOG
    while [ ! -f "$SCHEDULER_FILE" ]; do
        echo "run-dask-process.sh: $SCHEDULER_FILE not present - waiting to start workers..."
        sleep 2
    done
    echo "RUNNING: \"python -m dask_cuda.cli.dask_cuda_worker $WORKER_ARGS\"" > $WORKERS_LOG
    python -m dask_cuda.cli.dask_cuda_worker $WORKER_ARGS >> $WORKERS_LOG 2>&1 &
    worker_pid=$!
    echo "worker(s) started."
fi

# This script will not return until the following background process
# have been completed/killed.
if [[ $worker_pid != "" ]]; then
    echo "waiting for worker pid $worker_pid to finish before exiting script..."
    wait $worker_pid
fi
if [[ $scheduler_pid != "" ]]; then
    echo "waiting for scheduler pid $scheduler_pid to finish before exiting script..."
    wait $scheduler_pid
fi

