#!/bin/sh
# This script is not based on POSIX but XCP-ng running on CentOS/Bash only.

CMDNAME=`basename $0`
function usage() {
  echo "Usage: ${CMDNAME} [-del]"
  echo "    -d : set TCP NIC offload disable."
  echo "    -e : set TCP NIC offload enable."
  echo "    -l : show current setting of other-config"
}

if [ ${#} -ne 1 ]; then
  usage
  exit 0
fi

if [ "$1" == "-l" ]; then	# show current config.
  echo "=== PIF Config ==="
  for PIFUUID in `xe pif-list --minimal | sed -e 's/,/ /g'`; do
    DEVICE=`xe pif-param-get uuid=${PIFUUID} param-name=device`
    CURRENT=`xe pif-param-get uuid=${PIFUUID} param-name=other-config`
    echo ${PIFUUID} : $DEVICE : $CURRENT
  done
  echo "=== VIF Config ==="
  for VIFUUID in `xe vif-list --minimal currently-attached=true  | sed -e 's/,/ /g'`; do
    DEVICE=`xe vif-param-get uuid=${VIFUUID} param-name=device`
    CURRENT=`xe vif-param-get uuid=${VIFUUID} param-name=other-config`
    echo $VIFUUID : $DEVICE : $CURRENT
  done
  echo "=== ip link ==="
  ip link show | grep -P 'vif\d+\.\d+'
  exit 0
elif [ "$1" == "-d" ]; then	# set TCP NIC offload disable.
  echo "=== PIF Config ==="
  for PIFUUID in `xe pif-list --minimal | sed -e 's/,/ /g'`; do
    xe pif-param-set uuid=$PIFUUID other-config:ethtool-gso="off";
    xe pif-param-set uuid=$PIFUUID other-config:ethtool-ufo="off";
    xe pif-param-set uuid=$PIFUUID other-config:ethtool-tso="off";
    xe pif-param-set uuid=$PIFUUID other-config:ethtool-sg="off";
    xe pif-param-set uuid=$PIFUUID other-config:ethtool-tx="off";
    xe pif-param-set uuid=$PIFUUID other-config:ethtool-rx="off";
  done
  echo "=== VIF Config ==="
  for VIFUUID in `xe vif-list --minimal currently-attached=true  | sed -e 's/,/ /g'`; do
    xe vif-param-set uuid=$VIFUUID other-config:ethtool-gso="off"
    xe vif-param-set uuid=$VIFUUID other-config:ethtool-ufo="off"
    xe vif-param-set uuid=$VIFUUID other-config:ethtool-tso="off"
    xe vif-param-set uuid=$VIFUUID other-config:ethtool-sg="off"
    xe vif-param-set uuid=$VIFUUID other-config:ethtool-tx="off"
    xe vif-param-set uuid=$VIFUUID other-config:ethtool-rx="off"			
  done
  echo "=== ip link ==="
  for VIF in `ip link show | grep -P 'vif\d+\.\d+' | grep "qlen 32" | cut -d":" -f2`; do
    ifconfig ${VIF} txqueuelen 1500
  done
  exit 0
elif [ "$1" 00 "-e" ]; then	# set TCP NIC offload enable.
  echo "=== PIF Config ==="
  for PIFUUID in `xe pif-list --minimal | sed -e 's/,/ /g'`; do
    xe pif-param-clear uuid=$PIFUUID param-name=other-config
  done
  echo "=== VIF Config ==="
  for VIFUUID in `xe vif-list --minimal currently-attached=true  | sed -e 's/,/ /g'`; do
    xe vif-param-clear uuid=$VIFUUID param-name=other-config
  done
  exit 0
fi

