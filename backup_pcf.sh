#!/bin/bash
# Script: pcf_backup.sh
# Author: mglynn@pivotal.io
# Tested w: Ubuntu Trusty Backup VM & PCF 1.7 on Azure
# Example Usage:
#   pcf_backup.sh   [backupdir] [days to keep]     [BOSH IP]      [BOSH ADMIN]     [BOSH PASSWD]
#   pcf_backup.sh "/pcf_backup"       "2"      "192.168.120.10"       admin         'bl4h!'
###############################################################
# requires awk, mysqldump, rabbitmqadmin, bosh-cli, azure-cli, rabbitmq-dump-queue
###############################################################
# sudo apt-get install ruby mysql-server python-pip nfs-common
# sudo gem install bosh_cli --no-ri --no-rdoc
# sudo pip install shyaml


set -e

#Input Args
BACKUP_DIR=$1
BACKUP_KEEP_DAYS=$2
BOSH_TARGET=$3
BOSH_ADMIN=$4
BOSH_PASSWORD=$5
#Configuration Vars - partial names of jobs in manifest OK
BOSH_ERT_MYSQL_PARTITION_NAME="mysql-partition"
BOSH_ERT_MYSQL_PROXY_PARTITION_NAME="mysql_proxy-partition"
BOSH_ERT_CC_PARTITION_NAME="cloud_controller-partition"
BOSH_ERT_NFS_PARTITION_NAME="nfs_server-partition"
BOSH_MYSQL_PROXY_PARTITION_NAME="proxy-partition"
BOSH_MYSQL_PARTITION_NAME="mysql-partition"
BOSH_RABBITMQ_PROXY_PARTITION_NAME="rabbitmq-haproxy-partition"
BOSH_RABBITMQ_SERVER_PARTITION_NAME="rabbitmq-server-partition"
declare -a DEPLOYMENTS=(
"cf-azure:ert"
"p-mysql:mysql"
"p-rabbitmq:rabbitmq"
)


#### Verify Backup Dir Exists
if [ ! -d $BACKUP_DIR ]; then
        mkdir -p $BACKUP_DIR
fi

#### Creating Backup Sub-Folder with Timestamp name

BACKUP_DIR_DATETIME=$(date +"%m-%d-%Y-%r" | tr -d " ")
BACKUP_DIR_PATH=$BACKUP_DIR"/"$BACKUP_DIR_DATETIME
mkdir -p $BACKUP_DIR_PATH

#### Authenticate to BOSH

bosh -n target https://$BOSH_TARGET
bosh -n login $BOSH_ADMIN $BOSH_PASSWORD


#rm -rf /tmp/$BOSH_CF_DEPLOYMENT.yml

#### Functions

function fn_get_job_index {
    JOBS_TRIGGER=0
    JOBS_COUNT=$(cat /tmp/$1.yml | shyaml get-values jobs | grep "^name: " | wc -l)
    while [ $JOBS_TRIGGER -eq 0 ]; do
          for (( x=0; x<=$JOBS_COUNT-1; x++ )); do
            JOB_NAME=$(cat /tmp/$1.yml | shyaml get-value jobs.$x.name | sed -n 1p)
            if [[ $JOB_NAME == *$2* ]]; then
              JOBS_TRIGGER=1
              echo $x
              break
            fi
          done
          if [ $JOBS_TRIGGER -eq 0 ]; then
            echo "No Jobs found matching "$2
            exit 1
          fi
    done
}

function fn_get_job_ip {
    JOB_IP=$(cat /tmp/$1.yml | shyaml get-value jobs.$2.networks.0.static_ips | sed -n 1p)
    echo $JOB_IP | tr -d '-' | tr -d ' '
}

function fn_ert {
    #Read in ert manifest
    echo "Processing ERT Manifest "$1"..."
    MYSQL_PROXY_INDEX=$( fn_get_job_index $1 $BOSH_ERT_MYSQL_PROXY_PARTITION_NAME )
    MYSQL_PROXY_IP=$( fn_get_job_ip $1 $MYSQL_PROXY_INDEX )
    MYSQL_INDEX=$( fn_get_job_index $1 $BOSH_ERT_MYSQL_PARTITION_NAME )
    MYSQL_PASSWORD=$(cat /tmp/$1.yml | shyaml get-value jobs.$MYSQL_INDEX.properties.admin_password)
    CLOUD_CTRLR_INSTANCES=$(bosh vms $1 | grep $BOSH_ERT_CC_PARTITION_NAME | awk -F " " '{print$2}')

    #Shutdown All Cloud Controllers
    for y in ${CLOUD_CTRLR_INSTANCES[@]}; do
      JOB=$(echo $y | awk -F "/" '{print$1}')
      INDEX=$(echo $y | awk -F "/" '{print$2}')
      (echo bosh stop $JOB $INDEX) || (echo "Error Stopping Job $y" && exit 1)
    done

    # Backup all ERT Mysql Databases
    echo "Backing up ERT mysql databases ..."
    mysqldump -h $MYSQL_PROXY_IP -p$MYSQL_PASSWORD -uroot -v --all-databases > $BACKUP_DIR_PATH/ert-mysql.bak

    # Backup NFS
    echo "Backing up ERT nfs/blobstore ..."
    NFS_INDEX=$( fn_get_job_index $1 $BOSH_ERT_NFS_PARTITION_NAME )
    NFS_IP=$( fn_get_job_ip $1 $NFS_INDEX )
    if [ ! -d /tmp/blobstore ]; then
            mkdir -p /tmp/blobstore
    fi

    sudo mount -o ro,tcp $NFS_IP:/var/vcap/store /tmp/blobstore || sudo mount -o remount,ro,tcp $NFS_IP:/var/vcap/store /tmp/blobstore
    tar -cvzf $BACKUP_DIR_PATH/blobstore.tgz /tmp/bloblstore/shared/* -C /tmp/blobstore .

    #Start All Cloud Controllers
    for y in ${CLOUD_CTRLR_INSTANCES[@]}; do
      JOB=$(echo $y | awk -F "/" '{print$1}')
      INDEX=$(echo $y | awk -F "/" '{print$2}')
      (echo bosh start $JOB $INDEX) || (echo "Error Starting Job $y" && exit 1)
    done

    rm -rf /tmp/$1.yml
}

function fn_mysql {
    #Read in mysql manifest
    echo "Processing MYSQL Manifest "$1"..."
    TILE_MYSQL_PROXY_INDEX=$( fn_get_job_index $1 $BOSH_MYSQL_PROXY_PARTITION_NAME )
    TILE_MYSQL_PROXY_IP=$( fn_get_job_ip $1 $TILE_MYSQL_PROXY_INDEX )
    TILE_MYSQL_INDEX=$( fn_get_job_index $1 $BOSH_MYSQL_PARTITION_NAME )
    TILE_MYSQL_PASSWORD=$(cat /tmp/$1.yml | shyaml get-value jobs.$TILE_MYSQL_INDEX.properties.admin_password)

    #Backup all SQL databases from tile
    echo "Backing up MYSQL tile databases ..."
    mysqldump -h $TILE_MYSQL_PROXY_IP -p$TILE_MYSQL_PASSWORD -uroot -v --all-databases > $BACKUP_DIR_PATH/tile-mysql.bak

    rm -rf /tmp/$1.yml
}

function fn_rabbitmq {
    #Read in rabbitmq manifest
    echo "Processing RABBITMQ Manifest "$1"..."
    TILE_RABBITMQ_PROXY_INDEX=$( fn_get_job_index $1 $BOSH_RABBITMQ_PROXY_PARTITION_NAME )
    TILE_RABBITMQ_PROXY_IP=$( fn_get_job_ip $1 $TILE_RABBITMQ_PROXY_INDEX )
    TILE_RABBITMQ_SERVER_INDEX=$( fn_get_job_index $1 $BOSH_RABBITMQ_SERVER_PARTITION_NAME )
    TILE_RABBITMQ_SERVER_ADMIN=$(cat /tmp/$1.yml | shyaml get-value jobs.$TILE_RABBITMQ_SERVER_INDEX.properties.rabbitmq-server.administrators.management.username)
    TILE_RABBITMQ_SERVER_PASSWORD=$(cat /tmp/$1.yml | shyaml get-value jobs.$TILE_RABBITMQ_SERVER_INDEX.properties.rabbitmq-server.administrators.management.password)

    # Get rabbitmqadmin binary
    wget $TILE_RABBITMQ_PROXY_IP:15672/cli/rabbitmqadmin -O $BACKUP_DIR_PATH/rabbitmqadmin
    chmod 755 $BACKUP_DIR_PATH/rabbitmqadmin

    # Backup Rabbit Configuration
    echo "Backing up RABBITMQ tile config ..."
    $BACKUP_DIR_PATH/rabbitmqadmin \
    -H $TILE_RABBITMQ_PROXY_IP \
    -u $TILE_RABBITMQ_SERVER_ADMIN \
    -p $TILE_RABBITMQ_SERVER_PASSWORD \
    export $BACKUP_DIR_PATH/tile-rabbitmq.cfg

    # Backing up Qs with Messages (Optional)
      QDB_ROOT="/var/lib/qdb/data/queues/default"
      RABBIT_QS=($($BACKUP_DIR_PATH/rabbitmqadmin -H $TILE_RABBITMQ_PROXY_IP -u $TILE_RABBITMQ_SERVER_ADMIN -p $TILE_RABBITMQ_SERVER_PASSWORD list queues messages consumers vhost name durable | tr -d ' ' | grep "^|[0-9].*"))

      # Get rabbit-dump-q tool binary
      wget https://github.com/virtmerlin/rabbitmq-dump-queue/raw/master/release/rabbitmq-dump-queue-1.1-linux-amd64/rabbitmq-dump-queue -O $BACKUP_DIR_PATH/rabbitmq-dump-queue
      chmod 755 $BACKUP_DIR_PATH/rabbitmq-dump-queue

      # Backup Rabbit Qs with messages
      for (( z=0; z<=${#RABBIT_QS[@]}-1; z++ )); do
      # /tmp/rabbitmqadmin -H 172.19.11.26 -u rabbitmq -p rabbitmq list queues messages consumers vhost name
        Q_MSG_COUNT=$(echo ${RABBIT_QS[$z]} | awk -F "|" '{print$2}')
        Q_VHOST=$(echo ${RABBIT_QS[$z]} | awk -F "|" '{print$4}')
        Q_NAME=$(echo ${RABBIT_QS[$z]} | awk -F "|" '{print$5}')
        if [ $Q_MSG_COUNT -gt 0 ]; then
          echo "Will backup $Q_NAME on $Q_VHOST ..."
          mkdir -p $BACKUP_DIR_PATH/rabbitqs/$Q_VHOST/$Q_NAME
          echo $BACKUP_DIR_PATH/rabbitmq-dump-queue -uri="amqp://$TILE_RABBITMQ_SERVER_ADMIN:$TILE_RABBITMQ_SERVER_PASSWORD@$TILE_RABBITMQ_PROXY_IP$Q_VHOST" \
          -queue=$Q_NAME -max-messages=10000 -output-dir=$BACKUP_DIR_PATH/rabbitqs/$Q_VHOST/$Q_NAME
          $BACKUP_DIR_PATH/rabbitmq-dump-queue -uri="amqp://$TILE_RABBITMQ_SERVER_ADMIN:$TILE_RABBITMQ_SERVER_PASSWORD@$TILE_RABBITMQ_PROXY_IP$Q_VHOST" \
          -queue=$Q_NAME -max-messages=10000 -output-dir=$BACKUP_DIR_PATH/rabbitqs/$Q_VHOST/$Q_NAME
        fi
      done

      rm -rf /tmp/$1.yml
}

####Backup Deployments Main Logic
for (( i=0; i<=${#DEPLOYMENTS[@]}-1; i++ )); do
  # Split keypair from Deployment
  BOSH_CF_DEPLOYMENT=$(echo ${DEPLOYMENTS[$i]} | awk -F ":" '{print$1}')
  BOSH_CF_DEPLOYMENT_TYPE=$(echo ${DEPLOYMENTS[$i]} | awk -F ":" '{print$2}')
  # Grab Manifest
  bosh -n download manifest $BOSH_CF_DEPLOYMENT /tmp/$BOSH_CF_DEPLOYMENT.yml
  bosh -n deployment /tmp/$BOSH_CF_DEPLOYMENT.yml

  case "$BOSH_CF_DEPLOYMENT_TYPE" in
      ert)
        fn_ert  $BOSH_CF_DEPLOYMENT
        ;;
      mysql)
        fn_mysql  $BOSH_CF_DEPLOYMENT
        ;;
      rabbitmq)
        fn_rabbitmq  $BOSH_CF_DEPLOYMENT
          ;;
      *)
        echo "Deployment Backup Function Not Found"
        exit 1
  esac
done

#### Wipe Older BACKUP Folders in given Backup Dir
find $BACKUP_DIR/* -type d -ctime +$BACKUP_KEEP_DAYS -exec rm -rf {} \;
