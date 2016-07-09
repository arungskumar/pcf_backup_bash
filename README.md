## Backup a PCF deployment w/out cfops
### [`pcf_backup.sh`](https://github.com/virtmerlin/pcf_backup_bash/blob/master/backup_pcf.sh)


Documentation on manual backup of PCF can be found [here](https://docs.pivotal.io/pivotalcf/1-7/customizing/backup-restore/backup-pcf.html).  This tool is intended to assist with automating the process.

####Features

- Will Stop Cloud Controllers, backup all databases in ERT mysql instance, and restart cloud controllers
- Will Backup Mysql Tile
- Will Backup RabbitMQ Tile (Config & any Active Q data)
- Will Backup Redis (Dedicated Nodes Only && Requires Rsync on the backup node)
- Will report success/fail, duration, and size to Datadog (Optional)
- Only needs Bosh IP & credentials as input,  detects other params from reading manifests
- Easily scheduled to run via cron on a dedicated Linux backup VM


####Requirements

Common Linux cli tools such as : `awk, mysqldump, rabbitmqadmin, bosh-cli, rabbitmq-dump-queue`

Most can be installed easily:

- `sudo apt-get install ruby mysql-server python-pip nfs-common rsync`
- `sudo gem install bosh_cli --no-ri --no-rdoc`
- `sudo pip install shyaml`
- `wget https://github.com/virtmerlin/rabbitmq-dump-queue/raw/master/release/rabbitmq-dump-queue-1.1-linux-amd64/rabbitmq-dump-queue`
- `rabbitmqadmin` can be downloaded fromPCF deployed Rabbit via `http://[RABBIT_PROXY]:15672/cli/`


####Usage

Tested w: Ubuntu Trusty Dedicated Backup VM & PCF 1.7.x on Azure
##### Example Usage:
   pcf_backup.sh [backupdir] [days to keep] [BOSH IP] [BOSH ADMIN]  [BOSH PASSWD] [DD API KEY]
   
   `pcf_backup.sh "/pcf_backup"  "2"  "192.168.120.10"  admin 'bl4h!' "deff5701541e366c2b0547a11c64ca01"`
   
   DataDog Key is optional,  simply not passing the arg will prevent attempts to report stats
   
####Useful Backup Links

- [Backing Up Pivotal Cloud Foundry](https://docs.pivotal.io/pivotalcf/1-7/customizing/backup-restore/backup-pcf.html)
- [Backing Up Mysql](https://dev.mysql.com/doc/mysql-enterprise-backup/4.0/en/mysqlbackup.restore.html)
- [Backing Up Rabbit Config](https://www.rabbitmq.com/management-cli.html)
- [Backing Up Rabbit Messages w/ QDB](http://qdb.io/)
- [Backing Up Rabbit Messages w/ raw cli in BASH](https://github.com/virtmerlin/rabbitmq-dump-queue)
- [Backing Up Redis](http://redis.io/topics/persistence)