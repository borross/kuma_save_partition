#!/bin/bash
#RU_PRESALE_TEAM_BORIS_O

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

usage="\n$(basename "$0") [-h] [-export] [-import] <ARGUMENTS> -- program for emporting and exporting information from ClickHouse in KUMA \n
\n
where:\n
    ${YELLOW}-h${NC} -- show this help text\n
    ${YELLOW}-export <YYYY-MM-DD> <YYYY-MM-DD>${NC} -- export KUMA partitions from <YYYY-MM-DD> to <YYYY-MM-DD>\n
    ${YELLOW}-import partitions_from_*.txt${NC} -- importing partitions from archives (must be near the sript) by list partitions_from_*.txt (must be near the sript)\n
    ${YELLOW}-arch_before_delete <full_path> <clusterID>${NC} -- archive partition which will be auto deleted in 1 day\n
\n
"


# VARs
startDate=$2
endDate=$3
startDateCH=${startDate//-}
endDateCH=${endDate//-}
pwd=$(pwd)
freeze_stor_pwd=/opt/kaspersky/kuma/clickhouse/data/shadow/freezed_partition/store/*/*/
clientCH=/opt/kaspersky/kuma/clickhouse/bin/client.sh
tableCHname=kuma.events_local_v2
archPart=arch_before_delete_partition.txt
archPartIDs=arch_before_delete_partition_IDs.txt
login="private-api"
pass="q123123Q!"
kuma_IP="10.68.85.126"
auto_tenant_create="0"
need_to_del_keys="0"
is_local_core="1"
#kuma_cluster_UUID="7a7539f1-ab1d-469c-a82a-2df550f286b3"


if [[ $# -eq 0 ]]; then
    echo -e "${RED}No arguments supplied${NC}"
    echo -e $usage
    exit 1
fi

case $1 in
    "-h")
    echo -e $usage
    ;;

    "-export")
        dateDiffDays=$(($(($(date +%s -d $endDateCH)-$(date +%s -d $startDateCH)))/86400))
        outputFileName=partitions_from_$startDate-$endDate.txt
        for i in $(seq 0 $dateDiffDays); do
            dateFromRange=$(date +%Y%m%d -d "$startDate + $i days")
            $clientCH -d kuma --multiline --query "SELECT partition, name, partition_id FROM system.parts WHERE substring(partition,2,8)='$dateFromRange' AND table='events_local_v2' AND NOT positionCaseInsensitive(partition,'audit')>0;" > $outputFileName
        done
        
        if [[ -s $outputFileName ]]; then
            echo -e "${YELLOW}See partition info in file $outputFileName${NC}"
            
            for i in $(cat $outputFileName | awk '{print $3}' | sort -u); do
                start_time_sec=`date +%s`
                $clientCH -d kuma --multiline --query "ALTER TABLE $tableCHname ON CLUSTER kuma FREEZE PARTITION ID '$i' WITH NAME 'freezed_partition';" &>/dev/null
                echo Creating archive $i.tar.gz for $i partition ID, please wait ...
                cd $freeze_stor_pwd
                tar -czf $pwd/$i.tar.gz $i* &>/dev/null
                $clientCH -d kuma --multiline --query "ALTER TABLE $tableCHname ON CLUSTER kuma UNFREEZE PARTITION ID '$i' WITH NAME 'freezed_partition';" &>/dev/null
                cd $pwd
                finish_time_sec=`date +%s`
                echo "Elapsed archivation time: $(( ($finish_time_sec) - ($start_time_sec) )) seconds."
            done
            
            echo -e "${GREEN}Exporting Done!${NC}"
        else
            # outputFileName is EMPTY
            rm -f $outputFileName
            echo -e "${RED}Nothing to export! \n No partitions for chosen date(s)! \n Deleting file $outputFileName...${NC}"
        fi
    ;;

    "-import")
        if [[ -s $2 ]]; then
            for i in $(cat $2 | awk '{print $3}' | sort -u); do
                echo Unpacking archive $i.tar.gz, please wait ...
                tar -xf $i.tar.gz -C /opt/kaspersky/kuma/clickhouse/data/data/kuma/events_local_v2/detached/
                chown -R kuma:kuma /opt/kaspersky/kuma/clickhouse/data/data/kuma/events_local_v2/detached/*
                $clientCH -d kuma --multiline --query "ALTER TABLE $tableCHname ATTACH PARTITION ID '$i';" &>/dev/null
                if [[ $? -eq 1 ]]; then
                    echo -e "${RED}Error importing partition $i! Skipping it...${NC}" >&2
                    rm -rf /opt/kaspersky/kuma/clickhouse/data/data/kuma/events_local_v2/detached/$i/
                    continue
                fi
            done
            
            echo -e "${GREEN}Importing Done!${NC}"
            echo -e "${YELLOW}You must create any Tenant on KUMA with ID(s), firsty trying to do this automatically.${NC}"
            TENANT_CNT=0
            TENANT_NAME="TENANT_"

            if [[ $auto_tenant_create -eq 1 && $is_local_core -eq 0 ]]; then                
                echo -e "${YELLOW}Enter please SSH KUMA CORE user.${NC}"
                read ssh_core_login
                if [[ $(cat ~/.ssh/authorized_keys | grep -c "$(hostname -f)") -eq 0 ]]; then
                    ssh-copy-id $ssh_core_login@$kuma_IP
                    need_to_del_keys="1"
                fi

            fi

            for i in $(cat $2 | cut -d "'" -f 2 | sed 's/\\//g' | sort -u); do
                if [[ $auto_tenant_create -eq 1 ]]; then
                    echo "/opt/kaspersky/kuma/mongodb/bin/mongo kuma --eval 'db.tenants.find({\"_id\": { \$eq: \"$i\"} });' | grep -c true" > cmd.txt
                    
                    if [[ $is_local_core -eq 0 ]]; then
                        ID_exists=$(ssh $ssh_core_login@$kuma_IP < cmd.txt; echo $some | awk '{print $NF}')
                    else
                        ID_exists=$(ssh $ssh_core_login@$kuma_IP < cmd.txt; echo $some | awk '{print $NF}')
                    fi
                    
                    if [[ $ID_exists -eq 0 ]]; then
                        TENANT_NAME+=$($i | cut -d '-' -f 1)
                        /opt/kaspersky/kuma/mongodb/bin/mongo kuma --eval 'db.tenants.insertOne({"_id": "'$i'", "name": "'$TENANT_NAME'", "description": "", "main": false, "disabled": false, "eps": 0, "epsLimit": 100, "createdAt": 1670580800905, "updatedAt": 1670580800905});' &> /dev/null
                        if [[ $? -eq 0 ]]; then                    
                            echo -e "${GREEN}AUTO Success! Created ID: $i, tenant name: $TENANT_NAME${NC}"
                        else
                            echo -e "${RED}No AUTO Creation! Check Mongo Collection kuma.tenants. You must create Tenant MANUALLY ID: $i${NC}"
                        fi
                        let TENANT_CNT=TENANT_CNT+1
                        TENANT_NAME="TENANT_"
                    else
                        echo -e "${GREEN}AUTO! Tenant ID already exist!${NC}"
                    fi
                else
                    echo -e "${RED}No AUTO Creation! Check Mongo Collection kuma.tenants. You must create Tenant MANUALLY ID: $i${NC}"
                fi
            done

            if [[ $need_to_del_keys -eq 1 ]]; then
                echo -e "${YELLOW}Deleting saved SSH keys.${NC}"
                ssh $ssh_core_login@$kuma_IP "sed -i \"/$(hostname -f)/d\" ~/.ssh/authorized_keys"
                sed -i "/$kuma_IP/d" ~/.ssh/authorized_keys
            fi
        else
            # outputFileName is EMPTY
            echo -e "${RED}Nothing to import! \n File $2 is EMPTY!${NC}"
        fi
    ;;

    "-arch_before_delete")
        if [[ ! $# -eq 3 ]]; then
            echo -e "${RED}Not enough arguments supplied${NC}"
            echo -e $usage
            exit 1
        fi

        kuma_cluster_UUID=$3

        # Get Cookies to file cookie.txt
        curl -s -k -D cookie.txt --location 'https://'${kuma_IP}':7220/api/login' --header 'Content-Type: application/json' --header 'Cookie: kuma_session=; XSRF-TOKEN=' --data '{"Login": "'${login}'","Password":"'${pass}'"}' >> /dev/null

        # Write to file desired partition deletion time
        for i in $(XSRF_TOKEN=$(cat cookie.txt | grep XSRF-TOKEN | awk '{print $2}') ; kuma_session=$(cat cookie.txt | grep kuma_session | awk '{print $2}') ; curl -s -k --location 'https://'${kuma_IP}':7220/api/private/services/indices?cluster='${kuma_cluster_UUID}'' --header 'Cookie: '${XSRF_TOKEN}' '${kuma_session}'' | jq -c '.[] | select(.spaceID | index("audit") | not) | .deleteAt'); do diffDays=$(($(($(date +%s -d @$i)/1000-$(date +%s)))/86400)); if [[ "$diffDays" -eq "1" ]]; then echo $i > arch_before_delete_partition_date.txt; fi; done

        # Get partition name by deletion time from file
        XSRF_TOKEN=$(cat cookie.txt | grep XSRF-TOKEN | awk '{print $2}') ; kuma_session=$(cat cookie.txt | grep kuma_session | awk '{print $2}') ; curl -s -k --location 'https://'${kuma_IP}':7220/api/private/services/indices?cluster='${kuma_cluster_UUID}'' --header 'Cookie: '${XSRF_TOKEN}' '${kuma_session}'' | jq -c '.[] | select(.deleteAt=='$(cat arch_before_delete_partition_date.txt)') | .name' > $archPart

        sed -i 's/\"//g' $archPart

        # Get part IDs by name
        $clientCH -d kuma --multiline --query "SELECT partition, name, partition_id FROM system.parts WHERE partition='$(sed 's/\x27/\\'"'"'/g' $archPart)'" > $archPartIDs

        if [[ -s $archPartIDs ]]; then
            for i in $(cat $archPartIDs | awk '{print $3}' | sort -u); do
                start_time_sec=`date +%s`
                $clientCH -d kuma --multiline --query "ALTER TABLE $tableCHname ON CLUSTER kuma FREEZE PARTITION ID '$i' WITH NAME 'freezed_partition';" &>/dev/null
                echo Creating archive $i.tar.gz for $i partition ID, please wait ...
                cd $freeze_stor_pwd
                tar -czf $pwd/$i.tar.gz $i* &>/dev/null
                $clientCH -d kuma --multiline --query "ALTER TABLE $tableCHname ON CLUSTER kuma UNFREEZE PARTITION ID '$i' WITH NAME 'freezed_partition';" &>/dev/null
                cd $pwd
                finish_time_sec=`date +%s`                
                echo "Elapsed archivation time: $(( ($finish_time_sec) - ($start_time_sec) )) seconds."
            done
            echo -e "${YELLOW}Moving archive to $2!${NC}"
            mv $i.tar.gz $2
            echo -e "${GREEN}Exporting Done!${NC}"
        else
            # archPart is EMPTY
            echo -e "${RED}Nothing to do! \n File $archPartIDs is EMPTY! \n OR No path for archive!${NC}"
        fi
    ;;

    * )
        echo -e $usage
    ;;
esac