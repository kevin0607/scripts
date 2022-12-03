PATH1=.
VARS=$PATH1/vars.json
SUBNET="172.22.0."
IMAGE=$(jq -r '.[]|.image' $VARS)
NODES=$(jq -r '.[]|.nodes' $VARS)
COMASTER=$(jq -r '.[]|.comaster' $VARS)
GTID=$(jq -r '.[]|.gtid' $VARS)
BINLOG=$(jq -r '.[]|.binlog' $VARS)
repl_password=$(jq -r '.[]|.repl_password' $VARS)
root_password=$(jq -r '.[]|.root_password' $VARS)
monitoring=$(jq -r '.[]|.monitoring' $VARS)
fo=$(jq -r '.[]|.fo' $VARS)
j=$(echo $RANDOM|head -c 2)
master=''
slaves=''
for(( i=1; i<= $NODES; i++ ))
do 
k=$(expr $i + "$j")

if [ $i -eq 1 ] || ([ $i -eq 2 ] && [ "$COMASTER" -eq 1 ]); 
then 
 n=$(echo master_$i$RANDOM|head -c 14)
else
 n=$(echo slave_$i$RANDOM|head -c 14)
fi 


docker run \
       --platform linux/x86_64 \
       --name "$n" \
       -e MYSQL_ROOT_PASSWORD="$root_password" \
       --ip="$SUBNET$k" \
       --hostname $n \
       --net=network_docker \
       -dit \
       "$IMAGE" \
       --default-authentication-plugin=mysql_native_password \
       --gtid-mode=$GTID \
       --enforce-gtid-consistency=$GTID \
       --binlog-format=$BINLOG \
       --log-slave-updates \
       --bind-address=0.0.0.0 \
       --server-id=$k \
       --report-host=$n \
       --log-bin=$n \
       --read-only=0

#docker cp ./my.cnf "$n":/etc/
if [[ "$n" == "master_"* ]]; then
  masters="$masters $n"
else
  slaves="$slaves $n"
fi

done


sleep $(($NODES * 8))


for p in `echo $masters$slaves`
do 
docker exec "$p" mysql  -uroot -p$root_password -e"CREATE USER 'repl'@'$SUBNET%' IDENTIFIED BY '$repl_password';GRANT REPLICATION SLAVE ON *.* to 'repl'@'$SUBNET%';FLUSH PRIVILEGES;"

if [[ $p == "master_"* ]]; then
        if [[ $GTID == "ON" ]]; then
                   if [[ "$p" == "master_1"* ]]; then
                          master1_gtid=`docker exec "$p" mysql -uroot  -p$root_password -ss -e"show master status"|awk '{print $3}'`
                          master1_repl_pos=`echo "MASTER_HOST=\"$p\", MASTER_AUTO_POSITION=1"`
                   fi
                   if [[ "$p" == "master_2"* ]]; then
                          master2_gtid=`docker exec "$p" mysql -uroot  -p$root_password -ss -e"show master status"|awk '{print $3}'`
                          master2_repl_pos=`echo "MASTER_HOST=\"$p\", MASTER_AUTO_POSITION=1"`
                   fi
        else
                   if [[ "$p" == "master_1"* ]]; then
                          master1_repl_pos=`docker exec "$p" mysql -uroot  -p$root_password -ss -e"show master status"|awk -v var="$p" '{print "MASTER_HOST=\""var"\", MASTER_LOG_FILE=\""$1"\" , MASTER_LOG_POS="$2}'`
                   elif [[ "$p" == "master_2"* ]] 
                        then
                           master2_repl_pos=`docker exec "$p" mysql -uroot  -p$root_password -ss -e"show master status"|awk -v var="$p" '{print "MASTER_HOST=\""var"\", MASTER_LOG_FILE=\""$1"\" , MASTER_LOG_POS="$2}'`            
                   fi 
       fi      

fi


if [[ "$p" == "slave_"* ]]; then
       docker exec "$p" mysql -uroot -p$root_password -e"SET GLOBAL GTID_PURGED='$master1_gtid';CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$repl_password', $master1_repl_pos; START SLAVE;"
fi

done

for q in `echo $masters`
do
  if [[ "$q" == "master_1"* ]]; then
            docker exec "$q" mysql -uroot -p$root_password -e"SET GLOBAL GTID_PURGED='$master2_gtid'; CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$repl_password', $master2_repl_pos; START SLAVE;" 
                        
  fi

  if [[ "$q" == "master_2"* ]]; then
            docker exec "$q" mysql -uroot -p$root_password -e" SET GLOBAL GTID_PURGED='$master1_gtid'; CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$repl_password', $master1_repl_pos; START SLAVE;"

  fi
done
