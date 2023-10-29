#!/bin/bash
# Description:  This script is usefull to help us to rump-up rds read replica
# Maintainer:   Agus Wibawa

set -e

WORKDIR="$PWD"
# load configuration
source "$WORKDIR/config.conf"

# database target
DBEXEC="$(which mysql)"
AWSCLI="$(which aws)"
STATUS=$WORKDIR/status.txt
LOG="$WORKDIR/$(date '+%Y%m%d').log"
LINE="----------------------------------------------------------------------------"
export AWS_PROFILE="$AWSPROFILE";

# get endpoint rds from instance name
getEP () {
  EP=$($AWSCLI rds describe-db-instances \
    --query 'DBInstances[*].[Endpoint.Address]' \
    --filters Name=db-instance-id,Values=$1 \
    --output text);
  MYSQL_DB=$EP;
}

# load getEP on start-up script
getEP "$DBINSTANCE";

# logging function
logg () {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG"
}

# check config
checkConf () {
  source "$WORKDIR/config.conf"
  echo $LINE;
  echo "AWS_PROFILE = $AWSPROFILE";
  echo "RDS Instance Name = $DBINSTANCE";
  echo "RDS Endpoint = $MYSQL_DB";
  echo "";
  echo $LINE;
}

# check mysql network connection
checkDB () {
  if ! $DBEXEC -h $1 -u$USR  -p$PASS -e "SELECT @@HOSTNAME" > /dev/null; then
    echo "Connection failed to $MYSQL_DB"
    logg $LINE && logg "Connection test failed to $1"
    exit;
  else logg $LINE && logg "Connection test succeeded to $1"
  fi
}

# check seconds behind master
checkRep () {
  $DBEXEC -h $1 -u$USR  -p$PASS -e "SHOW SLAVE STATUS\G" > $STATUS
  MASTER_LOG_FILE=$(grep -w Master_Log_File $STATUS| awk '{print $2}');
  MASTER_LOG_POS=$(grep -w Read_Master_Log_Pos $STATUS| awk '{print $2}');
  SLAVE_IO_RUNNING=$(grep -w Slave_IO_Running $STATUS| awk '{print $2}');
  SLAVE_SQL_RUNNING=$(grep -w Slave_SQL_Running $STATUS| awk '{print $2}');
  SBM=$(grep -w Seconds_Behind_Master $STATUS| awk '{print $2}');

  logg "$LINE"
  logg "Database : $1"
  logg "Master_Log_File : $MASTER_LOG_FILE"
  logg "Read_Master_Log_Pos : $MASTER_LOG_POS"
  logg "Slave_IO_Running : $SLAVE_IO_RUNNING"
  logg "Slave_SQL_Running : $SLAVE_SQL_RUNNING"
  logg "Seconds_Behind_Master : $SBM"
}

# stop replication
stopRep () {
  logg "Stop replication on $1 ... starting"
  logg "CALL mysql.rds_stop_replication;"
  $DBEXEC -h $1 -u$USR  -p$PASS -e "CALL mysql.rds_stop_replication;"
  logg "Stop replication on $1 ...completed"
  checkRep $MYSQL_DB;
}

# start replication
startRep () {
  logg "$LINE"
  logg "Start replication on $1 ... starting"
  logg "CALL mysql.rds_start_replication;"
  $DBEXEC -h $1 -u$USR  -p$PASS -e "CALL mysql.rds_start_replication;"
  logg "Start replication on $1 ... completed"
  logg ""
  checkRep "$MYSQL_DB";
}

rampUP () {
  logg "$LINE"
  logg "Rump-up $DBINSTANCE to $DBCLASS with Parameter group $PARAMGROUP... starting"
  $AWSCLI rds modify-db-instance \
    --db-instance-identifier $DBINSTANCE \
    --option-group-name $OPTIONGROUP \
    --db-parameter-group-name $PARAMGROUP \
    --db-instance-class $DBCLASS \
    --apply-immediately
  logg ""
}

rampUP2x () {
  logg "$LINE"
  logg "Rump-up $DBINSTANCE to $DBCLASS2 with Parameter group $PARAMGROUP2 ... starting"
  $AWSCLI rds modify-db-instance \
    --db-instance-identifier $DBINSTANCE \
    --option-group-name $OPTIONGROUP \
    --db-parameter-group-name $PARAMGROUP2 \
    --db-instance-class $DBCLASS2 \
    --apply-immediately
  logg ""
}

rampUP4x () {
  logg "$LINE"
  logg "Rump-up $DBINSTANCE to $DBCLASS4 with Parameter group $PARAMGROUP4 ... starting"
  $AWSCLI rds modify-db-instance \
    --db-instance-identifier $DBINSTANCE \
    --option-group-name $OPTIONGROUP \
    --db-parameter-group-name $PARAMGROUP4 \
    --db-instance-class $DBCLASS4 \
    --apply-immediately
  logg ""
}

# get database connection from cloudwatch
getDBCon () {
  start="$(date -v -7H +%Y-%m-%dT%H:%M:00Z)"
  end="$(date -v -6H +%Y-%m-%dT%H:%M:00Z)"
  result="$($AWSCLI cloudwatch get-metric-statistics \
    --metric-name DatabaseConnections \
    --start-time $start \
    --end-time $end \
    --period 300 --namespace AWS/RDS  \
    --statistics Average \
    --dimensions Name=DBInstanceIdentifier,Value=$1)"
  tmpResult=$(echo "$result" | tail -1 |awk '{print $2}')
  logg "$LINE" && logg "Average database connection $DBINSTANCE since 1 hour ago : $tmpResult"
}

reboot () {
  logg "$LINE"
  logg "$DBINSTANCE reboot... starting"
  $AWSCLI rds reboot-db-instance \
    --db-instance-identifier "$DBINSTANCE"
  logg ""
}

# get status RDS
getRDS () {

  while true; do
    rds="$($AWSCLI rds describe-db-instances \
      --db-instance-identifier "$DBINSTANCE" \
      --output text |head -1 |tail -1 | awk '{print $14}')"
    logg "$LINE"
    logg "Database RDS $DBINSTANCE status : $rds"
    if [[ "$rds" == "available" ]] 
      then break
    fi
    sleep 60
  done
}

# get status snapshot
getSnap () {

  while true; do
    stat="$($AWSCLI rds describe-db-snapshots \
     --db-snapshot-identifier $DBSNAPSHOT \
     |awk '{print $21 "-" $22 "-" $23}')"
    logg "$LINE"
    logg "Snapshot $DBSNAPSHOT status : $stat"
    if [[ "$stat" == "region-manual-available" ]] 
        then break
    fi
    sleep 60
  done

}

createSnap () {
  logg "$LINE"
  logg "Creating snapshot $DBSNAPSHOT ... starting"
  $AWSCLI rds create-db-snapshot \
    --db-instance-identifier "$DBINSTANCE" \
    --db-snapshot-identifier "$DBSNAPSHOT"
}

restoreSnap () {
  logg "$LINE"
  logg "Restore snapshot $DBSNAPSHOT to $DBINSTANCENEW ... starting"
  $AWSCLI rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier "$DBINSTANCENEW" \
    --db-snapshot-identifier "$DBSNAPSHOT" \
    --db-instance-class "$DBCLASS" \
    --no-multi-az \
    --publicly-accessible \
    --option-group-name "$OPTIONGROUP" \
    --db-parameter-group-name "$PARAMGROUP" \
    --vpc-security-group-ids "sg-1ec83f7a" "sg-71d0c10c" \
    --db-subnet-group-name "twsdb" \
    --no-copy-tags-to-snapshot \
    --auto-minor-version-upgrade
}

setRep () {

  logg "$LINE"
  logg "Setup replication on $1 MasterFile=$MASTERLOGFILE MasterPos=$MASTERLOGPOS ... starting"
  $DBEXEC -h $1 -u$USR  -p$PASS -e "CALL mysql.rds_set_external_master(
    '172.30.3.37',
    3306,
    '$USRREP',
    '$PASSREP',
    '$MASTERLOGFILE',
    $MASTERLOGPOS,
    1);"
  logg "Setup replication on $1 ... completed"
  logg ""
  checkRep "$1";
}

# remove all temporary files
cleanup () {
  rm -f $STATUS
}

# actions menu
PS3="Select item please: "
items=(
      "Reload Config" #1
      "Connection Test" #2
      "Replication Status" #3
      "Setup Replication" #4
      "Start Replication"  #5
      "Stop Replication"  #6
      "Database Status" #7
      "Create Snapshot" #8
      "Restore Snapshot" #9
      "Snapshot Status" #10
      "Reboot") #11

clear;
echo "$LINE"
echo "AWS RDS Rump-up Tools v.3.0"
echo "Here will be show the Short Instruction, the details will be on README.md"
echo "All activities will be recorded on logging file yyyymmdd.log"
checkConf;


while true; do
    select item in "${items[@]}" Quit
    do
        case $REPLY in
            1) checkConf "$DBINSTANCE"; break;;
            2) checkDB "$MYSQL_DB"; break;;
            3) checkRep "$MYSQL_DB"; break;;
            4) setRep "$MYSQL_DB"; break;;
            5) startRep "$MYSQL_DB"; break;;
            6) stopRep "$MYSQL_DB"; break;;
            7) getRDS "$DBINSTANCE"; break;;
            8) createSnap; break;;
            9) restoreSnap; break;;
            10) getSnap "$DBINSTANCE"; break;;
            11) reboot; break;;
            $((${#items[@]}+1))) cleanup && echo "Thanks!"; break 2;;
            *) echo "Ooops - unknown choice $REPLY"; break;
        esac
    done
done
