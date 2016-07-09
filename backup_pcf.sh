#!/bin/bash
# Script: pcf_backup.sh
# Author: mglynn@pivotal.io
# Tested w: Ubuntu Trusty Backup VM & PCF 1.7 on Azure
# Example Usage:
#   pcf_backup.sh   [backupdir] [days to keep]     [BOSH IP]      [BOSH ADMIN]     [BOSH PASSWD]
#   pcf_backup.sh "/pcf_backup"       "2"      "192.168.120.10"       admin         'bl4h!'
############################################################################################
# requires awk, mysqldump, rabbitmqadmin, bosh-cli, azure-cli, rabbitmq-dump-queue, rsync  #
############################################################################################
# sudo apt-get install ruby mysql-server python-pip nfs-common rsync
# sudo gem install bosh_cli --no-ri --no-rdoc
# sudo pip install shyaml
# * Enable remote access in /etc/default/rsync && /etc/rsyncd.conf && /etc/rsyncd.secrets -- used for redis backup function
# * Setup backup user as a sudoer with ALL=NOPASSWD: ALL --visudo

##############################
# Config                     #
##############################

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
"p-redis:redis"
)
declare -a BLOBS=(
"cc-buildpacks"
"cc-droplets"
"cc-packages"
"cc-resources"
)

##############################
# Functions                  #
##############################

function error_exit {
   echo "backup_pcf: ${1:-"Error"}" >>$LOGFILE 2>&1
   exit 1
}

function fn_get_job_index {
    JOBS_TRIGGER=0
    JOBS_COUNT=$(cat /tmp/$1.yml | shyaml get-values jobs | grep "^name: " | wc -l) || error_exit "fn_get_job_index"
    while [ $JOBS_TRIGGER -eq 0 ]; do
          for (( x=0; x<=$JOBS_COUNT-1; x++ )); do
            JOB_NAME=$(cat /tmp/$1.yml | shyaml get-value jobs.$x.name | sed -n 1p) || error_exit "fn_get_job_index"
            if [[ $JOB_NAME == *$2* ]]; then
              JOBS_TRIGGER=1
              echo $x
              break
            fi
          done
          if [ $JOBS_TRIGGER -eq 0 ]; then
            error_exit "BOSH job not found"
          fi
    done
}

function fn_get_job_ip {
    JOB_IP=$(cat /tmp/$1.yml | shyaml get-value jobs.$2.networks.0.static_ips | sed -n 1p) || error_exit "fn_get_job_ip"
    echo $JOB_IP | tr -d '-' | tr -d ' '
}

function fn_ert {
    #Read in ert manifest
    echo "##########################" >>$LOGFILE 2>&1
    echo "Processing ERT Manifest "$1"..." >>$LOGFILE 2>&1
    echo "##########################" >>$LOGFILE 2>&1
    MYSQL_PROXY_INDEX=$( fn_get_job_index $1 $BOSH_ERT_MYSQL_PROXY_PARTITION_NAME ) || error_exit "fn_ert"
    MYSQL_PROXY_IP=$( fn_get_job_ip $1 $MYSQL_PROXY_INDEX ) || error_exit "fn_ert"
    MYSQL_INDEX=$( fn_get_job_index $1 $BOSH_ERT_MYSQL_PARTITION_NAME ) || error_exit "fn_ert"
    MYSQL_PASSWORD=$(cat /tmp/$1.yml | shyaml get-value jobs.$MYSQL_INDEX.properties.admin_password) || error_exit "fn_ert"
    CLOUD_CTRLR_INSTANCES=$(bosh vms $1 | grep $BOSH_ERT_CC_PARTITION_NAME | awk -F " " '{print$2}') || error_exit "fn_ert"

    #Shutdown All Cloud Controllers
    for y in ${CLOUD_CTRLR_INSTANCES[@]}; do
      JOB=$(echo $y | awk -F "/" '{print$1}')
      INDEX=$(echo $y | awk -F "/" '{print$2}')
      (echo bosh stop $JOB $INDEX >>$LOGFILE 2>&1) || error_exit "fn_ert - Error Stopping BOSH job"
    done

    # Backup all ERT Mysql Databases
    echo "Backing up ERT mysql databases ..." >>$LOGFILE 2>&1
    mysqldump -h $MYSQL_PROXY_IP -p$MYSQL_PASSWORD -uroot -v --all-databases > $BACKUP_DIR_PATH/ert-mysql.bak || error_exit "fn_ert - Error Backing Up MYSQL"

    # Backup NFS
    echo "Backing up ERT nfs/blobstore ..." >>$LOGFILE 2>&1
    NFS_INDEX=$( fn_get_job_index $1 $BOSH_ERT_NFS_PARTITION_NAME ) || error_exit "fn_ert - Error Backing Up NFS Blobstore"
    NFS_IP=$( fn_get_job_ip $1 $NFS_INDEX )
    if [ ! -d /tmp/blobstore ]; then
            mkdir -p /tmp/blobstore >>$LOGFILE 2>&1 || error_exit "fn_ert - Error Backing Up NFS Blobstore"
    fi

    if grep -qs '/var/vcap/store' /proc/mounts; then
          sudo mount -o remount,ro,tcp $NFS_IP:/var/vcap/store /tmp/blobstore >>$LOGFILE 2>&1 || error_exit "fn_ert - Error Mounting NFS Blobstore"
    else
          sudo mount -o ro,tcp $NFS_IP:/var/vcap/store /tmp/blobstore >>$LOGFILE 2>&1 || error_exit "fn_ert - Error Mounting NFS Blobstore"
    fi

    for z in ${BLOBS[@]}; do
       echo "Backing up ERT nfs/blobstore/$z ..." >>$LOGFILE 2>&1
       tar -cvzf $BACKUP_DIR_PATH/blobstore-$z.tgz  -C /tmp/blobstore/shared/$z . >>$LOGFILE 2>&1 ||  error_exit "fn_ert - Error creating NFS tarball for $z"
    done

    #Start All Cloud Controllers
    for y in ${CLOUD_CTRLR_INSTANCES[@]}; do
      JOB=$(echo $y | awk -F "/" '{print$1}')
      INDEX=$(echo $y | awk -F "/" '{print$2}')
      (echo bosh start $JOB $INDEX >>$LOGFILE 2>&1) || error_exit "fn_ert - Error Stopping BOSH job"
    done

    rm -rf /tmp/$1.yml  || error_exit "fn_ert - Error removing tmp manifest"
}

function fn_mysql {
    #Read in mysql manifest
    echo "##########################" >>$LOGFILE 2>&1
    echo "Processing MYSQL Manifest "$1"..." >>$LOGFILE 2>&1
    echo "##########################" >>$LOGFILE 2>&1
    TILE_MYSQL_PROXY_INDEX=$( fn_get_job_index $1 $BOSH_MYSQL_PROXY_PARTITION_NAME )
    TILE_MYSQL_PROXY_IP=$( fn_get_job_ip $1 $TILE_MYSQL_PROXY_INDEX )
    TILE_MYSQL_INDEX=$( fn_get_job_index $1 $BOSH_MYSQL_PARTITION_NAME )
    TILE_MYSQL_PASSWORD=$(cat /tmp/$1.yml | shyaml get-value jobs.$TILE_MYSQL_INDEX.properties.admin_password) || error_exit "fn_mysql - Error getting MYSQL Creds"

    #Backup all SQL databases from tile
    echo "Backing up MYSQL tile databases ..." >>$LOGFILE 2>&1
    mysqldump -h $TILE_MYSQL_PROXY_IP -p$TILE_MYSQL_PASSWORD -uroot -v --all-databases > $BACKUP_DIR_PATH/tile-mysql.bak || error_exit "fn_mysql - Error Dumping Mysql"

    rm -rf /tmp/$1.yml || error_exit "fn_mysql - Error removing tmp manifest"
}

function fn_rabbitmq {
    #Read in rabbitmq manifest
    echo "##########################" >>$LOGFILE 2>&1
    echo "Processing RABBITMQ Manifest "$1"..." >>$LOGFILE 2>&1
    echo "##########################" >>$LOGFILE 2>&1
    TILE_RABBITMQ_PROXY_INDEX=$( fn_get_job_index $1 $BOSH_RABBITMQ_PROXY_PARTITION_NAME )
    TILE_RABBITMQ_PROXY_IP=$( fn_get_job_ip $1 $TILE_RABBITMQ_PROXY_INDEX )
    TILE_RABBITMQ_SERVER_INDEX=$( fn_get_job_index $1 $BOSH_RABBITMQ_SERVER_PARTITION_NAME )
    TILE_RABBITMQ_SERVER_ADMIN=$(cat /tmp/$1.yml | shyaml get-value jobs.$TILE_RABBITMQ_SERVER_INDEX.properties.rabbitmq-server.administrators.management.username) || error_exit "fn_rabbitmq - Error getting rabbit creds/user"
    TILE_RABBITMQ_SERVER_PASSWORD=$(cat /tmp/$1.yml | shyaml get-value jobs.$TILE_RABBITMQ_SERVER_INDEX.properties.rabbitmq-server.administrators.management.password) || error_exit "fn_rabbitmq - Error getting rabbit creds/passwd"

    # Get rabbitmqadmin binary
    wget $TILE_RABBITMQ_PROXY_IP:15672/cli/rabbitmqadmin -O $BACKUP_DIR_PATH/rabbitmqadmin >>$LOGFILE 2>&1 || error_exit "fn_rabbitmq - Error Getting rabbit tools/rabbitmqadmin"
    chmod 755 $BACKUP_DIR_PATH/rabbitmqadmin || error_exit "fn_rabbitmq - Error Getting rabbit tools/rabbitmqadmin"

    # Backup Rabbit Configuration
    echo "Backing up RABBITMQ tile config ..." >>$LOGFILE 2>&1
    $BACKUP_DIR_PATH/rabbitmqadmin \
    -H $TILE_RABBITMQ_PROXY_IP \
    -u $TILE_RABBITMQ_SERVER_ADMIN \
    -p $TILE_RABBITMQ_SERVER_PASSWORD \
    export $BACKUP_DIR_PATH/tile-rabbitmq.cfg >>$LOGFILE 2>&1

    # Backing up Qs with Messages (Optional)
      RABBIT_QS=($($BACKUP_DIR_PATH/rabbitmqadmin -H $TILE_RABBITMQ_PROXY_IP -u $TILE_RABBITMQ_SERVER_ADMIN -p $TILE_RABBITMQ_SERVER_PASSWORD list queues messages consumers vhost name durable | tr -d ' ' | grep "^|[0-9].*"))  || error_exit "fn_rabbitmq - Error Getting qs to backup"

      # Get rabbit-dump-q tool binary
      wget https://github.com/virtmerlin/rabbitmq-dump-queue/raw/master/release/rabbitmq-dump-queue-1.1-linux-amd64/rabbitmq-dump-queue -O $BACKUP_DIR_PATH/rabbitmq-dump-queue  >>$LOGFILE 2>&1 || error_exit "fn_rabbitmq - Error Getting q dump tool"
      chmod 755 $BACKUP_DIR_PATH/rabbitmq-dump-queue  || error_exit "fn_rabbitmq - Error Getting q dump tool"

      # Backup Rabbit Qs with messages
      for (( z=0; z<=${#RABBIT_QS[@]}-1; z++ )); do
        Q_MSG_COUNT=$(echo ${RABBIT_QS[$z]} | awk -F "|" '{print$2}')
        Q_VHOST=$(echo ${RABBIT_QS[$z]} | awk -F "|" '{print$4}')
        Q_NAME=$(echo ${RABBIT_QS[$z]} | awk -F "|" '{print$5}')
        if [ $Q_MSG_COUNT -gt 0 ]; then
          echo "Will backup $Q_NAME on $Q_VHOST ..." >>$LOGFILE 2>&1
          mkdir -p $BACKUP_DIR_PATH/rabbitqs/$Q_VHOST/$Q_NAME || error_exit "fn_rabbitmq - Error creating dir for q ${RABBIT_QS[$z]}"
          if [[ $Q_VHOST != '/' ]]; then
            Q_VHOST='/'$Q_VHOST
          fi
          echo $BACKUP_DIR_PATH/rabbitmq-dump-queue -uri="amqp://$TILE_RABBITMQ_SERVER_ADMIN:$TILE_RABBITMQ_SERVER_PASSWORD@$TILE_RABBITMQ_PROXY_IP$Q_VHOST" \
          -queue=$Q_NAME -max-messages=10000 -output-dir=$BACKUP_DIR_PATH/rabbitqs/$Q_VHOST/$Q_NAME >>$LOGFILE 2>&1
          $BACKUP_DIR_PATH/rabbitmq-dump-queue -uri="amqp://$TILE_RABBITMQ_SERVER_ADMIN:$TILE_RABBITMQ_SERVER_PASSWORD@$TILE_RABBITMQ_PROXY_IP$Q_VHOST" \
          -queue=$Q_NAME -max-messages=10000 -output-dir=$BACKUP_DIR_PATH/rabbitqs/$Q_VHOST/$Q_NAME >>$LOGFILE 2>&1 || error_exit "fn_rabbitmq - Error dumping q ${RABBIT_QS[$z]}"
        fi
      done

      rm -rf /tmp/$1.yml || error_exit "fn_rabbitmq - Error removing tmp manifest"
}

function fn_redis {
    #Read in redis manifest
    echo "##########################" >>$LOGFILE 2>&1
    echo "Processing REDIS Manifest "$1"..." >>$LOGFILE 2>&1
    echo "##########################" >>$LOGFILE 2>&1
    echo "Starting rsync ..." >>$LOGFILE 2>&1
    sudo /etc/init.d/rsync start || error_exit "fn_redis - Error Starting rsync deamon"

    REDIS_DEDICATED_NODES=$(bosh vms $1 | grep dedicated | awk -F "|" '{print$2}' | awk '{print$1}' | tr "/" ":")

    for rnode in $REDIS_DEDICATED_NODES; do
      RNODE_ID=$(echo $rnode | awk -F ":" '{print$1}')
      RNODE_INDEX=$(echo $rnode | awk -F ":" '{print$2}')
      MYIP=$(sudo ifconfig eth0 | grep "inet addr" | awk '{print$2}' | tr -d "addr:")

      mkdir -p $BACKUP_DIR_PATH/redis/$RNODE_ID-$RNODE_INDEX
      BOSHCMD="bosh ssh $RNODE_ID $RNODE_INDEX 'export RSYNC_PASSWORD=\"pcfbackup\" && rsync -rltS /var/vcap/store/redis/* pcfbackup@$MYIP::pcfbackup/$BACKUP_DIR_DATETIME/redis/$RNODE_ID-$RNODE_INDEX/'"
      eval $BOSHCMD >>$LOGFILE 2>&1  || error_exit "fn_redis - Error Backing up $rnode"
    done

    echo "Stopping rsync ..." >>$LOGFILE 2>&1
    sudo /etc/init.d/rsync stop || error_exit "fn_redis - Error Stopping rsync deamon"

    rm -rf /tmp/$1.yml || error_exit "fn_redis - Error removing tmp manifest"
    
}
##############################
# End of Functions           #
##############################

#### Verify Backup Dir Exists

if [ ! -d $BACKUP_DIR ]; then
        mkdir -p $BACKUP_DIR || error_exit "pcf_backup - Error creating $BACKUP_DIR "
fi

#### Creating Backup Sub-Folder with Timestamp name

BACKUP_DIR_DATETIME=$(date +"%m-%d-%Y-%r" | tr -d " ")
BACKUP_DIR_PATH=$BACKUP_DIR"/"$BACKUP_DIR_DATETIME
mkdir -p $BACKUP_DIR_PATH || error_exit "pcf_backup - Error creating $BACKUP_DIR_PATH"

#### Set Logfile

LOGFILE=$BACKUP_DIR_PATH/pcf_backup.log

#### Authenticate to BOSH

bosh -n target https://$BOSH_TARGET >>$LOGFILE 2>&1 || error_exit "pcf_backup - Error creating Targeting $BOSH_TARGET "
bosh -n login $BOSH_ADMIN $BOSH_PASSWORD >>$LOGFILE 2>&1 || error_exit "pcf_backup - Error logging into $BOSH_TARGET "

####Backup Deployments Main Logic

STARTTIME=$(date +%s)
for (( i=0; i<=${#DEPLOYMENTS[@]}-1; i++ )); do
  # Split keypair from Deployment
  BOSH_CF_DEPLOYMENT=$(echo ${DEPLOYMENTS[$i]} | awk -F ":" '{print$1}')
  BOSH_CF_DEPLOYMENT_TYPE=$(echo ${DEPLOYMENTS[$i]} | awk -F ":" '{print$2}')
  # Grab Manifest
  bosh -n download manifest $BOSH_CF_DEPLOYMENT /tmp/$BOSH_CF_DEPLOYMENT.yml >>$LOGFILE 2>&1 || error_exit "pcf_backup - Error downloading manifest $BOSH_CF_DEPLOYMENT.yml"
  bosh -n deployment /tmp/$BOSH_CF_DEPLOYMENT.yml >>$LOGFILE 2>&1 || error_exit "pcf_backup - Error setting deployment for $BOSH_CF_DEPLOYMENT.yml"

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
      redis)
        fn_redis  $BOSH_CF_DEPLOYMENT
          ;;
      *)
        error_exit "Deployment Backup Function Not Found"
  esac
done

#### Calc Runtime in Minutes & Size in MB
ENDTIME=$(date +%s)
RUNTIME=$(($(($ENDTIME-$STARTTIME))/60))
SIZE=$(du -hsm $BACKUP_DIR_PATH | awk '{print$1}')

#### Wipe Older BACKUP Folders in given Backup Dir
find $BACKUP_DIR/* -type d ! -ctime -$BACKUP_KEEP_DAYS -exec rm -rf {} \;

echo "==================================================" >>$LOGFILE 2>&1
echo "Backups Completed and staged to $BACKUP_DIR_PATH" >>$LOGFILE 2>&1
echo "Backed up $SIZE MB in $RUNTIME Minutes" >>$LOGFILE 2>&1
echo "==================================================" >>$LOGFILE 2>&1
